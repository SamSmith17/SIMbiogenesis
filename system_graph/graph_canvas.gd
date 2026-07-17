extends Control
## GraphCanvas — pan/zoom drawing area for the solar circuit graph.
##
## Renders all graph items and connections stored in the GraphModel.
## Interactions: pan (MMB/RMB), zoom (wheel),
## item selection/drag (LMB), wire drag-to-connect (port dot LMB).

# ResourceKinds — global class_name from system_graph/data/resource_kinds.gd

# ---------------------------------------------------------------------------
# Color constants. Chrome (bg/border/text) redirected to UITheme, single
# source of truth. C_AMBER/C_GREEN/C_RED/C_WIRE_DC are NOT chrome — they are
# the semantic "energy" wire colors matching PORT_COLORS below (distinct
# shades from the UITheme accent colors) and stay local.
# ---------------------------------------------------------------------------
const C_CANVAS_BG  := UITheme.C_BG
const C_PANEL_BG   := Color(UITheme.C_PANEL, 0.96)      # deeper panel
const C_BORDER     := UITheme.C_BORDER
const C_PRIMARY    := UITheme.C_PRIMARY
const C_AMBER      := Color(0.941, 0.678, 0.306, 1.0)   # --energy-amber
const C_GREEN      := Color(0.063, 0.722, 0.506, 1.0)   # --energy-green
const C_RED        := Color(0.847, 0.329, 0.329, 1.0)   # #d9534f DC+
const C_TEXT       := UITheme.C_TEXT
const C_TEXT_S     := UITheme.C_TEXT_S
const C_TEXT_M     := UITheme.C_TEXT_M
const C_WIRE_DC    := Color(0.847, 0.329, 0.329, 1.0)   # DC positive wire

# Port colours — matches webapp getWireStyle (~9705)
const PORT_COLORS := {
	"positive":     Color(0.847, 0.329, 0.329, 1.0),  # DC+ red
	"negative":     Color(0.333, 0.333, 0.333, 1.0),  # DC- dark
	"ac":           Color(0.941, 0.678, 0.306, 1.0),  # AC orange
	"ac_240":       Color(1.000, 0.420, 0.420, 1.0),  # 240V red-ish
	"load":         Color(0.941, 0.820, 0.282, 1.0),  # 120V load yellow
	"parallel":     Color(0.231, 0.510, 0.965, 1.0),  # parallel blue
	"smart_battery":Color(0.063, 0.722, 0.506, 1.0),  # smart green
	"resource":     Color(0.580, 0.639, 0.722, 1.0),  # resource grey-blue
	"pv":           Color(0.961, 0.620, 0.043, 1.0),  # PV amber
}

# Node border colours by type
const NODE_BORDER_COLORS := {
	"panel":        Color(0.133, 0.827, 0.933, 1.0),  # cyan
	"battery":      Color(0.063, 0.722, 0.506, 1.0),  # green
	"controller":   Color(0.231, 0.510, 0.965, 1.0),  # blue
	"appliance":    Color(0.961, 0.620, 0.043, 1.0),  # amber
	"acload":       Color(0.961, 0.620, 0.043, 1.0),
	"breaker":      Color(0.937, 0.267, 0.267, 1.0),  # red
	"combiner":     Color(0.580, 0.639, 0.722, 1.0),  # grey-blue
	"solarcombiner":Color(0.133, 0.827, 0.933, 0.7),
	"acbreaker":    Color(0.937, 0.267, 0.267, 0.8),
	"acoutlet":     Color(0.941, 0.678, 0.306, 0.8),
	"smartbattery": Color(0.063, 0.722, 0.506, 1.0),
	"processor":    Color(0.580, 0.639, 0.722, 1.0),
	"resource":     Color(0.392, 0.447, 0.545, 1.0),
	"compound":     Color(0.565, 0.478, 0.902, 1.0),
	"shelly4pm":    Color(0.588, 0.322, 0.933, 1.0),  # violet — smart monitor
	"spiderbox":    Color(0.850, 0.450, 0.200, 1.0),  # amber — portable AC distro
	"breaker_panel":Color(0.820, 0.280, 0.280, 1.0),  # red — breaker panel
	"wind":         Color(0.360, 0.840, 0.780, 1.0),  # teal — wind turbine
	"hydro":        Color(0.250, 0.620, 0.950, 1.0),  # water blue — hydro turbine
	"catchment":    Color(0.200, 0.550, 0.900, 1.0),
	"plant":        Color(0.290, 0.720, 0.360, 1.0),  # leaf green — grow bed
}
const C_SELECTED_BORDER := Color(0.133, 0.827, 0.933, 1.0)   # cyan ring (SolarUI primary)
const C_ACTIVE_LOAD_GLOW := Color(0.149, 0.902, 0.467, 0.22)   # soft green when load is ON

# Default node sizes by type  [width, height] — graph-space pixels
const NODE_SIZES := {
	"panel":         [210, 128],
	"battery":       [128, 172],
	"controller":    [190, 160],
	"appliance":     [200, 128],
	"acload":        [200, 128],
	"breaker":       [ 80, 100],
	"combiner":      [108, 128],
	"solarcombiner": [118, 128],
	"acbreaker":     [ 80,  90],
	"acoutlet":      [104,  90],
	"smartbattery":  [128, 172],
	"processor":     [180, 140],
	"resource":      [136, 136],
	"compound":      [228, 152],
	"shelly4pm":     [200, 160],
	"spiderbox":     [220, 168],
	"breaker_panel": [200, 170],
	"wind":          [160, 138],
	"hydro":         [160, 138],
	"catchment":     [140, 112],
	"plant":         [170, 140],
}
const NODE_SIZE_DEFAULT := [158, 118]

# Handle definitions by type: Array of {id, polarity, rx, ry}
# rx/ry are fractional positions (0-1) relative to node width/height
const HANDLES := {
	"panel": [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
		# Optional, non-blocking — sunlight reaches every panel in the SoI
		# ambiently (mirrors real life: nothing "pipes" sunlight). Drawing
		# this wire from the sun PBI is purely visual/documentary and is
		# NEVER required for the panel to produce; see solar_pbi_selftest.gd.
		{"id": "sunlight_in", "polarity": "resource", "resource_kind": "sunlight", "rx": 0.5, "ry": 0.0},
	],
	# Wind/hydro generators wire like panels: DC out the bottom into a
	# controller PV input or a combiner.
	"wind": [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
		# Optional ambient atmosphere link from Wind PBI — turbines already
		# read WeatherService; this wire is documentary only.
		{"id": "wind_in", "polarity": "resource", "resource_kind": "wind", "rx": 0.5, "ry": 0.0},
	],
	"hydro": [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
	],
	"battery": [
		{"id": "positive", "polarity": "positive", "rx": 0.25, "ry": 0.0},
		{"id": "negative", "polarity": "negative", "rx": 0.75, "ry": 0.0},
	],
	"smartbattery": [
		{"id": "positive", "polarity": "smart_battery", "rx": 0.25, "ry": 0.0},
		{"id": "negative", "polarity": "negative",      "rx": 0.75, "ry": 0.0},
	],
	"controller": [
		{"id": "pvPositive",       "polarity": "positive", "rx": 0.25, "ry": 0.0},
		{"id": "pvNegative",       "polarity": "negative", "rx": 0.75, "ry": 0.0},
		{"id": "batteryPositive",  "polarity": "positive", "rx": 0.25, "ry": 1.0},
		{"id": "batteryNegative",  "polarity": "negative", "rx": 0.75, "ry": 1.0},
		{"id": "acOutput",         "polarity": "ac",       "rx": 0.5,  "ry": 1.0},
		{"id": "acOutputLeft",     "polarity": "ac",       "rx": 0.0,  "ry": 0.5},
		{"id": "acOutputTop",      "polarity": "ac",       "rx": 0.5,  "ry": 0.0},
		{"id": "acOutputBottom",   "polarity": "ac",       "rx": 0.5,  "ry": 1.0},
	],
	"appliance": [
		{"id": "input",       "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputRight",  "polarity": "load", "rx": 1.0, "ry": 0.5},
		{"id": "inputTop",    "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0},
	],
	"acload": [
		{"id": "input",       "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputRight",  "polarity": "load", "rx": 1.0, "ry": 0.5},
		{"id": "inputTop",    "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0},
	],
	"breaker": [
		{"id": "input",  "polarity": "positive", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "positive", "rx": 0.5, "ry": 1.0},
	],
	"combiner": [
		{"id": "input1",  "polarity": "positive", "rx": 0.2, "ry": 0.0},
		{"id": "input2",  "polarity": "positive", "rx": 0.5, "ry": 0.0},
		{"id": "input3",  "polarity": "positive", "rx": 0.8, "ry": 0.0},
		{"id": "output",  "polarity": "positive", "rx": 0.5, "ry": 1.0},
	],
	"acbreaker": [
		{"id": "input",  "polarity": "ac", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "ac", "rx": 0.5, "ry": 1.0},
	],
	"acoutlet": [
		{"id": "input",  "polarity": "ac",   "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "load", "rx": 0.5, "ry": 1.0},
	],
	"processor": [
		{"id": "power_in",  "polarity": "ac",       "rx": 0.5, "ry": 0.0},
		{"id": "output",    "polarity": "resource", "rx": 0.5, "ry": 1.0},
	],
	"resource": [
		{"id": "input",  "polarity": "resource", "resource_kind": "water", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "resource", "resource_kind": "water", "rx": 0.5, "ry": 1.0},
	],
	"catchment": [
		{"id": "input",  "polarity": "resource", "resource_kind": "water", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "resource", "resource_kind": "water", "rx": 0.5, "ry": 1.0},
	],
	# Grow bed / plant: sunlight is optional+non-blocking (ambient SoI PAR);
	# water is required; nutrients optional (if wired, then depleting blocks);
	# biomass out to a resource tank.
	"plant": [
		{"id": "sunlight_in", "polarity": "resource", "resource_kind": "sunlight", "rx": 0.5, "ry": 0.0},
		{"id": "water_in", "polarity": "resource", "resource_kind": "water", "rx": 0.22, "ry": 0.0},
		{"id": "nutrients_in", "polarity": "resource", "resource_kind": "nutrients", "rx": 0.78, "ry": 0.0},
		{"id": "biomass_out", "polarity": "resource", "resource_kind": "biomass", "rx": 0.5, "ry": 1.0},
	],
	"compound": [
		{"id": "in_ac_1",   "polarity": "ac",       "rx": 0.35, "ry": 0.0},
		{"id": "in_dc_1",   "polarity": "positive", "rx": 0.65, "ry": 0.0},
		{"id": "out_ac_1",  "polarity": "ac",       "rx": 0.35, "ry": 1.0},
		{"id": "out_dc_1",  "polarity": "positive", "rx": 0.65, "ry": 1.0},
	],
	# Shelly Pro 4PM: 1 AC feed in (top-center), 4 circuit outputs (bottom, evenly spaced)
	"shelly4pm": [
		{"id": "ac_in",     "polarity": "ac", "rx": 0.5, "ry": 0.0},
		{"id": "circuit_0", "polarity": "ac", "rx": 0.2, "ry": 1.0},
		{"id": "circuit_1", "polarity": "ac", "rx": 0.4, "ry": 1.0},
		{"id": "circuit_2", "polarity": "ac", "rx": 0.6, "ry": 1.0},
		{"id": "circuit_3", "polarity": "ac", "rx": 0.8, "ry": 1.0},
	],
	# Spiderbox: AC in → 6 switched outlets
	"spiderbox": [
		{"id": "ac_in",     "polarity": "ac", "rx": 0.5, "ry": 0.0},
		{"id": "circuit_0", "polarity": "ac", "rx": 0.12, "ry": 1.0},
		{"id": "circuit_1", "polarity": "ac", "rx": 0.28, "ry": 1.0},
		{"id": "circuit_2", "polarity": "ac", "rx": 0.44, "ry": 1.0},
		{"id": "circuit_3", "polarity": "ac", "rx": 0.60, "ry": 1.0},
		{"id": "circuit_4", "polarity": "ac", "rx": 0.76, "ry": 1.0},
		{"id": "circuit_5", "polarity": "ac", "rx": 0.92, "ry": 1.0},
	],
	# Breaker panel: AC in → branch breakers (up to 8 positions)
	"breaker_panel": [
		{"id": "ac_in",     "polarity": "ac", "rx": 0.5, "ry": 0.0},
		{"id": "circuit_0", "polarity": "ac", "rx": 0.10, "ry": 1.0},
		{"id": "circuit_1", "polarity": "ac", "rx": 0.21, "ry": 1.0},
		{"id": "circuit_2", "polarity": "ac", "rx": 0.32, "ry": 1.0},
		{"id": "circuit_3", "polarity": "ac", "rx": 0.43, "ry": 1.0},
		{"id": "circuit_4", "polarity": "ac", "rx": 0.54, "ry": 1.0},
		{"id": "circuit_5", "polarity": "ac", "rx": 0.65, "ry": 1.0},
		{"id": "circuit_6", "polarity": "ac", "rx": 0.76, "ry": 1.0},
		{"id": "circuit_7", "polarity": "ac", "rx": 0.87, "ry": 1.0},
	],
}

# ---------------------------------------------------------------------------
# Pan / zoom
# ---------------------------------------------------------------------------
## Canvas zoom range — keep in sync with GraphLayout.ZOOM_* (effectively
## unbounded for Site Plan + freeform framing / centimetre footprints).
const ZOOM_MIN       := GraphLayout.ZOOM_MIN
const ZOOM_MAX       := GraphLayout.ZOOM_MAX
const VALUE_EPS      := 0.0005
const REDRAW_INTERVAL := 0.05
## ~1 sim-hour per real-hour; used to scale flow-dot speed with simulation time_scale.
const REALTIME_SCALE_REF := 1.0 / 3600.0

## Wire chase + glow: peak reference power (W) for glow width scaling
const WIRE_GLOW_W_REF := 3500.0
## Minimum visible flow estimate for idle or unknown segments (W)
const WIRE_FLOW_FLOOR := 6.0
const WIRE_GLOW_MIN := 0.28
const WIRE_GLOW_MAX := 1.0
## Chase segments (bright dots) along the curve — base count; scaled up with power
const WIRE_CHASE_COUNT := 5
const WIRE_CHASE_SPACING := 0.09
## Chase segments threshold — below this actual-watt value the wire is considered dead
const WIRE_DEAD_W := 3.0
## Base wire body width (px); thickened at high power
const WIRE_BASE_W := 3.8

## Flow-rendering level-of-detail. The 5-pass glow halo + chase trail were
## tuned per-wire without regard to how many wires are on screen at once —
## fine with a handful of wires, wasteful with dozens. When many wires are
## visible, or the view is zoomed out enough that the extra detail isn't
## perceptible anyway, drop to a single glow pass and a single (bright-head)
## chase dot instead of a full trail — flow direction/activity stays legible,
## the decorative glow/trail depth does not. Recomputed once per
## _draw_connections() pass, read by the per-wire draw functions below.
const WIRE_LOD_HIGH_COUNT := 40
const WIRE_LOD_ZOOM_CUTOFF := 0.45
var _wire_lod_simplify: bool = false
## On-screen wire length (px) at which the reference segment counts below
## (28/34/24/28/30) apply at full strength; shorter/zoomed-out wires use
## proportionally fewer bezier segments down to a legibility floor.
const WIRE_SEG_REF_LEN := 260.0

var _pan:            Vector2 = Vector2.ZERO
var _zoom:           float   = 1.0
var _dragging:       bool    = false
var _last_drag_pos:  Vector2 = Vector2.ZERO
var _pan_button:     int     = -1
var pan_right_mouse: bool    = true
## Shift+LMB orbit while live SoI preview is showing behind the graph.
var _soi_orbit_dragging: bool = false
## Bottom-right (rect) or right-edge (circle) resize of the selected node.
var _resize_dragging: bool = false
var _resize_item_id: String = ""
var _resize_start_screen: Vector2 = Vector2.ZERO
var _resize_start_size: Vector2 = Vector2.ZERO  # freeform width/height or footprint_m
var _resize_circular: bool = false
const RESIZE_HANDLE_PX := 10.0
const RESIZE_HIT_PAD := 14.0

# ---------------------------------------------------------------------------
# Item drag
# ---------------------------------------------------------------------------
var _item_dragging:       bool    = false
var _item_drag_duplicated: bool    = false
var _item_drag_id:        String  = ""
var _item_drag_start_px:  Vector2 = Vector2.ZERO
var _item_drag_start_pos: Vector2 = Vector2.ZERO
const DRAG_THRESHOLD := 4.0
const TOUCH_DRAG_THRESHOLD := 10.0
const TOUCH_PORT_GRAB_MIN := 28.0
const TOUCH_SNAP_RADIUS_MIN := 44.0
## Minimum pick radius (px) for waypoints and ortho/metro segments on touch.
const TOUCH_SEGMENT_PICK_MIN := 22.0
const TOUCH_BODY_INSET := 28.0
const TOUCH_LOAD_BODY_INSET_X := 40.0
const TOUCH_LOAD_BODY_INSET_Y := 36.0
const TOUCH_DOUBLE_TAP_SEC := 0.38
const TOUCH_DOUBLE_TAP_DIST := 28.0

# ---------------------------------------------------------------------------
# Touch / pointer (Sharp panels and other touchscreens)
# ---------------------------------------------------------------------------
var _touch_positions: Dictionary = {}   # index -> Vector2
var _touch_primary_index: int = -1
var _touch_pan_active: bool = false
var _touch_pan_last_mid: Vector2 = Vector2.ZERO
## Mean finger distance from the touch centroid at the last drag frame — pinch
## zoom compares the current spread against this to derive a zoom factor.
var _touch_pan_last_spread: float = 0.0
var _last_tap_time: float = 0.0
var _last_tap_pos: Vector2 = Vector2.ZERO
var _last_tap_item_id: String = ""
var _touch_interaction: String = ""   # "", "item", "wire", "marquee", "pan"

# ---------------------------------------------------------------------------
# Wire drag (create-connection by dragging from a port)
# ---------------------------------------------------------------------------
var _wire_dragging:      bool       = false
var _wire_src_item_id:   String     = ""
var _wire_src_resource_kind: String = ""
## Set by SystemGraphView — supplies resource wire flow estimates.
var resource_flow_engine: RefCounted = null
## Set by SystemGraphView each tick from SolarUI:
## {battery_w: float (+charge / −discharge), valid: bool}. Wire animation
## prefers this real number over the |net| heuristic when valid.
var live_power_hint: Dictionary = {}
## Set by SystemGraphView — GraphModelPreviewService for GLB card thumbnails.
var model_preview_service: Node = null
var _wire_src_handle_id: String     = ""
var _wire_src_polarity:  String     = ""
var _wire_src_pos:       Vector2    = Vector2.ZERO
var _wire_src_tangent:   Vector2    = Vector2.ZERO
var _wire_cursor_pos:    Vector2    = Vector2.ZERO
var _wire_snap:          Dictionary = {}    # nearest compatible/incompatible port
var _wire_snap_valid:    bool       = false
## Drop-to-body hub target while dragging a resource wire onto a tank circle.
var _wire_hub_drop:      Dictionary = {}    # {item_id, kind, angle_rad, role}
const SNAP_RADIUS_PX := 24.0

## Drag an existing hub port around the perimeter (Alt+drag or dedicated grab).
var _hub_port_dragging:  bool   = false
var _hub_port_item_id:   String = ""
var _hub_port_handle_id: String = ""

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------
var selected_item_id:       String = ""
var selected_item_ids:      Array[String] = []
var selected_connection_id: String = ""
var _item_drag_ids:         Array[String] = []
var _item_drag_start_map:   Dictionary = {}
## Elevation view: starting elevation_m per dragged item (manual vertical moves).
var _item_drag_start_elev:  Dictionary = {}
var _marquee_selecting:     bool = false
var _marquee_start:         Vector2 = Vector2.ZERO
var _marquee_end:           Vector2 = Vector2.ZERO
## Screen-space hit rects for destroyed-controller Reset buttons (cleared each draw).
var _controller_reset_rects: Dictionary = {}
## Short-lived smoke puffs when a controller is destroyed: {item_id, center, age}.
var _destroy_fx: Array = []
var _needs_continuous_redraw: bool = false
## Alert-state pulse: decoupled from _flow_phase so it animates in build/paused
## mode too (a faulted/starved node should still pulse when the sim is paused),
## but at a coarse ~10 fps cadence instead of forcing the 20 fps interactive loop.
## `_alert_nodes_present` is derived from the previous draw (`_alert_seen_this_draw`)
## so we never scan the model separately just to pick a redraw rate.
var _alert_phase: float = 0.0
var _alert_nodes_present: bool = false
var _alert_seen_this_draw: bool = false
const ALERT_REDRAW_INTERVAL := 0.1
## Shared pill-badge renderer for the unified node-state chip.
var _state_badge := GraphNodeRendererV2.new()

## 2D wire waypoint drag (graph-space coords stored on connection).
var _waypoint_dragging:  bool   = false
var _waypoint_drag_conn: String = ""
var _waypoint_drag_idx:  int    = -1

## Orthogonal segment drag (draw.io-style: shift H/V runs).
var _ortho_seg_dragging:     bool                = false
var _ortho_seg_drag_conn:    String              = ""
var _ortho_seg_drag_idx:     int                 = -1
var _ortho_seg_drag_horiz:   bool                = false
var _ortho_drag_poly_start:  PackedVector2Array  = PackedVector2Array()
var _ortho_drag_start_graph: Vector2             = Vector2.ZERO

signal item_selected(item_id: String)
signal item_double_tapped(item_id: String)
signal items_multi_selected(item_ids: Array)
signal connection_selected(conn_id: String)
signal compound_open_requested(item_id: String)
signal layout_changed()
signal resource_containers_merged(target_id: String, absorbed_id: String, kind: String)
signal controller_reset_pressed(item_id: String)
## SoI live preview camera — Shift+drag orbit, Shift+wheel zoom.
signal soi_preview_orbit(relative: Vector2)
signal soi_preview_zoom(zoom_in: bool)
## Elevation: Shift+drag rotates the section heading (continuous).
signal elevation_heading_changed(heading_rad: float)
## Site Plan empty-canvas click (world designate tools).
signal site_background_clicked(screen_pos: Vector2)
## Designate tool mode: "" | "catchment" | "crop" (set by SystemGraphView).
var site_designate_mode: String = ""

# ---------------------------------------------------------------------------
# External references (set by SystemGraphView)
# ---------------------------------------------------------------------------
var model:        GraphModel = null
## True when inverter AC output is shed (low SOC / overload lockout).
var _ac_shed_active: bool = false
## "build" or "test" — set by SystemGraphView when mode toggle changes.
var current_mode: String     = "build"
## Layout projection: freeform | site | elevation.
var view_mode: String        = GraphSiteLayout.VIEW_FREEFORM
## Cross-section heading for elevation view (radians; 0 = +X / east).
var elevation_heading_rad: float = 0.0
## Vertical exaggeration for elevation profile (1 or 5).
var elevation_exaggeration: float = 5.0
## Current visible graph scope. Root matches historical behavior.
var active_scope_id: String  = "root"

var _flow_phase:   float = 0.0
var _redraw_accum: float = 0.0

# ---------------------------------------------------------------------------
# Shared styleboxes
# ---------------------------------------------------------------------------
var _sb_node_base: StyleBoxFlat


func _ready() -> void:
	clip_contents = true
	mouse_filter  = Control.MOUSE_FILTER_STOP
	focus_mode    = Control.FOCUS_NONE

	_sb_node_base = StyleBoxFlat.new()
	_sb_node_base.bg_color = Color(0.09, 0.12, 0.21, 0.97)
	_sb_node_base.set_border_width_all(1)
	_sb_node_base.border_color = Color(0.28, 0.36, 0.52, 0.85)
	_sb_node_base.set_corner_radius_all(12)
	_sb_node_base.shadow_color = Color(0.0, 0.0, 0.0, 0.28)
	_sb_node_base.shadow_size = 3


# ---------------------------------------------------------------------------
# Frame tick — drives flow animation and periodic redraws
# ---------------------------------------------------------------------------

## Live simulation time-scale multiplier — 1.0 = real-time, >1 = fast-forward.
## Stored each tick so wire renderers can scale chase dot count/speed.
var _sim_flow_mult: float = 1.0

func tick(delta: float, sim_time_scale: float = -1.0) -> void:
	_refresh_ac_shed_state()
	# Flow dots: only in test mode; speed tracks simulation time_scale; paused when scale <= 0.
	var flow_mult := 1.0
	if sim_time_scale >= 0.0:
		if sim_time_scale <= 0.0:
			flow_mult = 0.0
		else:
			flow_mult = clampf(sim_time_scale / REALTIME_SCALE_REF, 0.15, 80.0)
	_sim_flow_mult = flow_mult
	if current_mode == "test" and (flow_mult > 0.0 or _ac_shed_active):
		var vis_speed := 2.5 * clampf(pow(maxf(flow_mult, 0.2), 0.45), 0.15, 5.0)
		if _ac_shed_active and flow_mult <= 0.0:
			vis_speed = 6.0
		_flow_phase = fmod(_flow_phase + delta * vis_speed, TAU)
		_needs_continuous_redraw = true
	# Automation flash pulse decay
	if not _item_flash.is_empty():
		for fid: Variant in _item_flash.keys():
			_item_flash[fid] = float(_item_flash[fid]) - delta
			if float(_item_flash[fid]) <= 0.0:
				_item_flash.erase(fid)
		_needs_continuous_redraw = true
	# Smoke / destroy FX decay
	var fx_alive := false
	for i in range(_destroy_fx.size() - 1, -1, -1):
		var fx: Dictionary = _destroy_fx[i]
		fx["age"] = float(fx.get("age", 0.0)) + delta
		if float(fx["age"]) > 2.5:
			_destroy_fx.remove_at(i)
		else:
			fx_alive = true
	# Alert pulse advances independently of test-mode flow so faulted/starved
	# nodes still breathe while paused — but only drives a coarse ~10 fps redraw,
	# not the 20 fps interactive loop.
	if _alert_nodes_present:
		_alert_phase = fmod(_alert_phase + delta * 1.6, TAU)
	_redraw_accum += delta
	var interval := 0.25
	if current_mode == "test" or _needs_continuous_redraw or fx_alive:
		interval = REDRAW_INTERVAL
	elif _alert_nodes_present:
		interval = ALERT_REDRAW_INTERVAL
	if _redraw_accum >= interval:
		_redraw_accum = 0.0
		queue_redraw()
		if current_mode != "test" and not fx_alive:
			_needs_continuous_redraw = false


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func get_view_pan() -> Vector2:
	return _pan


func get_view_zoom() -> float:
	return _zoom


## Returns true when the event was consumed as SoI preview camera control.
func _handle_soi_preview_camera_input(event: InputEvent) -> bool:
	# Site Plan: scroll zoom is owned by the graph (2D+3D physically linked via
	# `_zoom`). Shift+wheel must NOT steal those events for orbit zoom.
	if view_mode == GraphSiteLayout.VIEW_SITE:
		if event is InputEventMouseButton:
			var mb_site := event as InputEventMouseButton
			if mb_site.button_index == MOUSE_BUTTON_WHEEL_UP \
					or mb_site.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				return false
	# Elevation: Shift+drag rotates the section heading continuously. Wheel stays
	# graph zoom. Do not steal events for freeform orbit zoom.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		return _handle_elevation_heading_input(event)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.shift_pressed:
			if not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _soi_orbit_dragging:
				_soi_orbit_dragging = false
				accept_event()
				return true
			return false
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			soi_preview_zoom.emit(true)
			accept_event()
			return true
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			soi_preview_zoom.emit(false)
			accept_event()
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_soi_orbit_dragging = mb.pressed
			accept_event()
			return true
		return false
	if event is InputEventMouseMotion:
		if not _soi_orbit_dragging:
			return false
		var mm := event as InputEventMouseMotion
		if not mm.shift_pressed:
			_soi_orbit_dragging = false
			return false
		soi_preview_orbit.emit(mm.relative)
		accept_event()
		return true
	return false


const _ELEV_HEADING_SENS := 0.006


func _handle_elevation_heading_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return false
		if not mb.shift_pressed:
			if not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _soi_orbit_dragging:
				_soi_orbit_dragging = false
				accept_event()
				return true
			return false
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_soi_orbit_dragging = mb.pressed
			accept_event()
			return true
		return false
	if event is InputEventMouseMotion:
		if not _soi_orbit_dragging:
			return false
		var mm := event as InputEventMouseMotion
		if not mm.shift_pressed:
			_soi_orbit_dragging = false
			return false
		elevation_heading_rad = fposmod(
				elevation_heading_rad - mm.relative.x * _ELEV_HEADING_SENS, TAU)
		elevation_heading_changed.emit(elevation_heading_rad)
		queue_redraw()
		accept_event()
		return true
	return false


func _gui_input(event: InputEvent) -> void:
	# Native touch — Sharp / Windows touchscreens often omit drag motion in emulated mouse.
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
		return
	if event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)
		return
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_zoom_at(mg.factor, mg.position)
		accept_event()
		return

	if _should_ignore_emulated_mouse(event):
		accept_event()
		return

	# SoI live preview camera (Shift+drag orbit, Shift+wheel zoom).
	if soi_live_preview and _handle_soi_preview_camera_input(event):
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not DisplayServer.is_touchscreen_available() and _touch_input_active():
			_clear_touch_state()
		# Pan start (MMB or RMB)
		var is_pan := mb.pressed and (
			mb.button_index == MOUSE_BUTTON_MIDDLE
			or (pan_right_mouse and mb.button_index == MOUSE_BUTTON_RIGHT)
		)
		if is_pan:
			_dragging      = true
			_pan_button    = mb.button_index
			_last_drag_pos = mb.position
			accept_event()
			return
		if not mb.pressed and _dragging and mb.button_index == _pan_button:
			_dragging   = false
			_pan_button = -1
			accept_event()
			return
		# Zoom
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(1.08, mb.position);  accept_event();  return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(1.0 / 1.08, mb.position);  accept_event();  return
		# Left click — begin possible wire/item drag or selection
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					var conn_dbl := _connection_at_screen(mb.position)
					if not conn_dbl.is_empty():
						var cid: String = str(conn_dbl.get("id", ""))
						if cid == selected_connection_id:
							_add_waypoint_on_connection(cid, mb.position)
						else:
							_select_connection(cid)
						accept_event()
						return
					var dbl_hit := _item_at_screen(mb.position)
					if not dbl_hit.is_empty() and str(dbl_hit.get("type", "")) == "compound":
						compound_open_requested.emit(dbl_hit.get("id", "") as String)
						accept_event()
						return
					if not dbl_hit.is_empty():
						item_double_tapped.emit(dbl_hit.get("id", "") as String)
						accept_event()
						return
				_on_pointer_press(mb.position)
				accept_event()
			else:
				_on_pointer_release(mb.position)
				accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and not pan_right_mouse:
			var wh := _waypoint_hit(mb.position)
			if not wh.is_empty():
				_remove_waypoint(str(wh.get("conn_id", "")), int(wh.get("index", -1)))
				accept_event()
				return

	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_DELETE, KEY_BACKSPACE] and not selected_connection_id.is_empty():
			var conn := model.get_connection(selected_connection_id) if model != null else {}
			if not conn.is_empty():
				var wps: Array = _waypoints_graph(conn)
				if not wps.is_empty():
					wps.pop_back()
					_set_waypoints_graph(selected_connection_id, wps)
					accept_event()
					return

	elif event is InputEventMouseMotion:
		_on_pointer_move((event as InputEventMouseMotion).position)
		if _dragging or _wire_dragging or _item_dragging or _marquee_selecting \
				or _waypoint_dragging or _ortho_seg_dragging or _resize_dragging:
			accept_event()


func _touch_input_active() -> bool:
	return _touch_primary_index >= 0 or not _touch_positions.is_empty()


func _should_ignore_emulated_mouse(event: InputEvent) -> bool:
	if not _touch_input_active():
		return false
	# Wheel zoom must always work (hybrid touch + mouse devices).
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return false
	# On non-touch devices, stale touch-emulation state would block all mouse input.
	if not DisplayServer.is_touchscreen_available():
		_clear_touch_state()
		return false
	# Block all emulated mouse traffic during touch — some panels emit RMB/MMB
	# on drag which would otherwise steal single-finger node moves as canvas pan.
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		return true
	return false


func _clear_touch_state() -> void:
	_touch_positions.clear()
	_touch_primary_index = -1
	_touch_pan_active = false
	_touch_interaction = ""


func _handle_screen_touch(st: InputEventScreenTouch) -> void:
	if st.pressed:
		# Clear any spurious mouse-emulation pan state before routing touch.
		_dragging = false
		_pan_button = -1
		_touch_positions[st.index] = st.position
		if _touch_positions.size() == 1:
			_touch_primary_index = st.index
			_touch_pan_active = false
			_touch_interaction = ""
			_on_pointer_press(st.position)
		elif _touch_positions.size() >= 2:
			_begin_touch_pan()
		accept_event()
	else:
		var was_two_finger := _touch_pan_active
		_touch_positions.erase(st.index)
		if st.index == _touch_primary_index:
			if not was_two_finger:
				_on_pointer_release(st.position)
			_touch_primary_index = -1
		if _touch_positions.size() < 2:
			_touch_pan_active = false
		elif _touch_pan_active:
			# Finger count changed but still pinching — re-baseline so the next
			# drag frame doesn't see a discontinuous centroid/spread jump.
			_touch_pan_last_mid = _touch_positions_midpoint()
			_touch_pan_last_spread = _touch_positions_spread()
		if _touch_positions.is_empty():
			_touch_interaction = ""
		accept_event()


func _handle_screen_drag(sd: InputEventScreenDrag) -> void:
	_touch_positions[sd.index] = sd.position
	if _touch_pan_active and _touch_interaction == "pan" and _touch_positions.size() >= 2:
		var mid := _touch_positions_midpoint()
		var spread := _touch_positions_spread()
		# Pan by centroid movement, then pinch-zoom anchored at the centroid so
		# the two gestures compose naturally (spread the fingers to zoom in while
		# sliding them to reposition the canvas).
		_pan += mid - _touch_pan_last_mid
		if _touch_pan_last_spread > 4.0 and spread > 4.0:
			_zoom_at(spread / _touch_pan_last_spread, mid)
		_touch_pan_last_mid = mid
		_touch_pan_last_spread = spread
		queue_redraw()
		accept_event()
		return
	if sd.index != _touch_primary_index:
		return
	_on_pointer_move(sd.position)
	if _dragging or _wire_dragging or _item_dragging or _marquee_selecting:
		accept_event()


func _touch_positions_midpoint() -> Vector2:
	if _touch_positions.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for pos: Vector2 in _touch_positions.values():
		sum += pos
	return sum / float(_touch_positions.size())


func _begin_touch_pan() -> void:
	_cancel_pointer_interaction()
	_touch_pan_active = true
	_touch_interaction = "pan"
	_touch_pan_last_mid = _touch_positions_midpoint()
	_touch_pan_last_spread = _touch_positions_spread()


## Mean distance of the active touch points from their centroid — a rotation-
## and translation-invariant proxy for pinch spread (works for 2+ fingers).
func _touch_positions_spread() -> float:
	if _touch_positions.size() < 2:
		return 0.0
	var mid := _touch_positions_midpoint()
	var d := 0.0
	for pos: Vector2 in _touch_positions.values():
		d += pos.distance_to(mid)
	return d / float(_touch_positions.size())


func _cancel_pointer_interaction() -> void:
	if _resize_dragging:
		_resize_dragging = false
		_resize_item_id = ""
	if _hub_port_dragging:
		_hub_port_dragging = false
		_hub_port_item_id = ""
		_hub_port_handle_id = ""
	if _wire_dragging:
		_wire_dragging = false
		_wire_snap = {}
		_wire_snap_valid = false
		_wire_hub_drop = {}
	if _item_dragging:
		_item_dragging = false
		_item_drag_id = ""
		_item_drag_ids.clear()
		_item_drag_start_map.clear()
	_marquee_selecting = false
	queue_redraw()


func _on_pointer_move(screen_pos: Vector2) -> void:
	if _resize_dragging:
		_on_resize_drag_move(screen_pos)
		return
	if _hub_port_dragging:
		_on_hub_port_drag_move(screen_pos)
		return
	if _ortho_seg_dragging and model != null and _ortho_seg_drag_idx >= 0:
		_apply_ortho_segment_drag(screen_pos)
		queue_redraw()
		return
	if _waypoint_dragging and model != null and _waypoint_drag_idx >= 0:
		var conn := model.get_connection(_waypoint_drag_conn)
		if not conn.is_empty():
			var wps: Array = _waypoints_graph(conn)
			if _waypoint_drag_idx < wps.size():
				var new_gpos := _screen_to_graph(screen_pos)
				if str(conn.get("line_style", "")) == "metro":
					# Snap the dragged waypoint's angle relative to the previous point
					# If there is a previous waypoint, use it; otherwise use the source port pos.
					var prev_gpos: Vector2
					if _waypoint_drag_idx > 0:
						prev_gpos = wps[_waypoint_drag_idx - 1] as Vector2
					else:
						var center := size * 0.5
						var src_info := _get_handle_info(
							str(conn.get("source_item_id", "")),
							str(conn.get("source_handle_id", "")),
							center,
							str(conn.get("target_item_id", "")),
							str(conn.get("polarity", "positive"))
						)
						prev_gpos = _screen_to_graph(src_info.get("pos", screen_pos) as Vector2)
					
					var vec := new_gpos - prev_gpos
					var dist := vec.length()
					if dist > 0.1:
						var angle := vec.angle()
						var snap_angle := roundf(angle / (PI / 4.0)) * (PI / 4.0)
						new_gpos = prev_gpos + Vector2(cos(snap_angle), sin(snap_angle)) * dist

				wps[_waypoint_drag_idx] = new_gpos
				_set_waypoints_graph(_waypoint_drag_conn, wps)
				queue_redraw()
		return
	# Touch item/wire drags take priority over any stray mouse-emulation pan.
	if _touch_interaction == "hub_port" and _hub_port_dragging:
		_on_hub_port_drag_move(screen_pos)
		return
	if _touch_interaction == "item" and _item_dragging:
		_on_item_drag_move(screen_pos)
		return
	if _touch_interaction == "wire" and _wire_dragging:
		_on_wire_drag_move(screen_pos)
		return
	if _touch_interaction == "pan" and _touch_pan_active:
		return
	if _dragging:
		_pan += screen_pos - _last_drag_pos
		_last_drag_pos = screen_pos
		queue_redraw()
	elif _wire_dragging:
		_on_wire_drag_move(screen_pos)
	elif _item_dragging:
		_on_item_drag_move(screen_pos)
	elif _marquee_selecting:
		_marquee_end = screen_pos
		queue_redraw()


func _on_pointer_press(screen_pos: Vector2) -> void:
	_on_lmb_press(screen_pos)


func _on_pointer_release(screen_pos: Vector2) -> void:
	_on_lmb_release(screen_pos)


func _effective_drag_threshold() -> float:
	if _touch_input_active() or DisplayServer.is_touchscreen_available():
		return TOUCH_DRAG_THRESHOLD
	return DRAG_THRESHOLD


func _try_emit_touch_double_tap(screen_pos: Vector2, item_id: String) -> bool:
	if item_id.is_empty():
		_reset_tap_tracking()
		return false
	var now := Time.get_ticks_msec() / 1000.0
	if (now - _last_tap_time) <= TOUCH_DOUBLE_TAP_SEC \
			and item_id == _last_tap_item_id \
			and screen_pos.distance_to(_last_tap_pos) <= TOUCH_DOUBLE_TAP_DIST:
		item_double_tapped.emit(item_id)
		_reset_tap_tracking()
		return true
	_last_tap_time = now
	_last_tap_pos = screen_pos
	_last_tap_item_id = item_id
	return false


func _reset_tap_tracking() -> void:
	_last_tap_time = 0.0
	_last_tap_pos = Vector2.ZERO
	_last_tap_item_id = ""


func _zoom_at(factor: float, screen_pos: Vector2) -> void:
	var center   := size * 0.5
	var old_zoom := _zoom
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(_zoom, old_zoom):
		return
	# Keep world point under the cursor stable. In Site Plan the SoI disc and
	# top-down SubViewport both scale with `_zoom` (4 px/m × zoom), so 2D and
	# 3D stay physically locked.
	var world := (screen_pos - center - _pan) / old_zoom
	_pan = screen_pos - center - world * _zoom
	queue_redraw()
	# SoI preview polls disc radius_px (includes zoom) each frame — do not emit
	# layout_changed here (that path autosaves + resyncs 3D props).


func _scope_of_item(item: Dictionary) -> String:
	return str(item.get("scope_id", "root"))


func _scope_of_conn(conn: Dictionary) -> String:
	return str(conn.get("scope_id", "root"))


## Per-draw cache: a single `_draw()` pass calls `_visible_items()` several times
## directly plus inside the solar/renewable/load helpers, and the model cannot
## change mid-draw. Computing the scoped list once and serving it for the whole
## pass turns ~6·N scans into 1·N. Only active between draw start and end; input
## hit-testing (outside draw) always computes fresh.
var _draw_cache_active: bool = false
var _cached_visible_items: Array = []
var _cached_visible_connections: Array = []


func _visible_items() -> Array:
	if _draw_cache_active:
		return _cached_visible_items
	return _compute_visible_items()


func _compute_visible_items() -> Array:
	if model == null:
		return []
	if model.has_method("get_items_in_scope"):
		return model.get_items_in_scope(active_scope_id)
	var out: Array = []
	for item: Dictionary in model.items:
		if _scope_of_item(item) == active_scope_id:
			out.append(item)
	return out


func _visible_connections() -> Array:
	if _draw_cache_active:
		return _cached_visible_connections
	return _compute_visible_connections()


func _compute_visible_connections() -> Array:
	if model == null:
		return []
	if model.has_method("get_connections_in_scope"):
		return model.get_connections_in_scope(active_scope_id)
	var out: Array = []
	for conn: Dictionary in model.connections:
		if _scope_of_conn(conn) == active_scope_id:
			out.append(conn)
	return out


## Cache for resolved absolute-path autoloads (SimMode / SoiService / AcPowerBus)
## so hot per-tick / per-node-per-draw code doesn't re-walk the scene tree. These
## are autoloads and effectively never freed, but re-resolve defensively if so.
var _node_ref_cache: Dictionary = {}

func _cached_autoload(abs_path: String) -> Node:
	var n: Node = _node_ref_cache.get(abs_path)
	if n != null and is_instance_valid(n):
		return n
	n = get_node_or_null(abs_path)
	if n != null:
		_node_ref_cache[abs_path] = n
	return n


func play_controller_destroy_fx(item_id: String, screen_center: Vector2) -> void:
	_destroy_fx.append({"item_id": item_id, "center": screen_center, "age": 0.0})
	_needs_continuous_redraw = true
	queue_redraw()


func request_continuous_redraw() -> void:
	_needs_continuous_redraw = true
	queue_redraw()


# Left-button press: port hit → wire drag; item hit → item drag.
func _on_lmb_press(screen_pos: Vector2) -> void:
	if model == null:
		return
	for rid in _controller_reset_rects:
		var item := model.get_item(str(rid))
		if item.is_empty():
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(specs.get("destroyed", false)):
			continue
		var rr: Rect2 = _controller_reset_rects[rid]
		# Enlarge the tappable area on touch without growing the drawn button.
		if _touch_input_active():
			rr = rr.grow(10.0)
		if rr.has_point(screen_pos):
			controller_reset_pressed.emit(str(rid))
			return
	_marquee_selecting = false
	var wp_hit := _waypoint_hit(screen_pos)
	if not wp_hit.is_empty():
		var conn_id := str(wp_hit.get("conn_id", ""))
		var conn := model.get_connection(conn_id) if model != null else {}
		if not conn.is_empty() and (conn.get("waypoints", []) as Array).is_empty():
			var center := size * 0.5
			var eff_wps := _effective_waypoints_screen(conn, center)
			var wps_graph: Array = []
			for wp_s in eff_wps:
				wps_graph.append(_screen_to_graph(wp_s))
			_set_waypoints_graph(conn_id, wps_graph)
		_waypoint_dragging = true
		_waypoint_drag_conn = conn_id
		_waypoint_drag_idx = int(wp_hit.get("index", -1))
		_touch_interaction = "waypoint"
		return
	var ortho_hit := _ortho_segment_hit(screen_pos)
	if not ortho_hit.is_empty():
		_begin_ortho_segment_drag(ortho_hit, screen_pos)
		return

	# Resize handle on the currently selected item (BR corner or right edge).
	var resize_id := _resize_handle_item_at(screen_pos)
	if not resize_id.is_empty():
		_begin_resize_drag(resize_id, screen_pos)
		return

	var hit := _item_at_screen(screen_pos)
	var touch_rules := _touch_input_active() or DisplayServer.is_touchscreen_available()

	# On touch, the node body interior wins over nearby port grab rings so
	# small load nodes remain draggable without accidentally starting wires.
	if touch_rules and not hit.is_empty() and _touch_point_in_item_body(screen_pos, hit):
		_begin_item_press(screen_pos, hit)
		return

	# Site / elevation: body wins over ports so tiny physical footprints stay
	# movable (ports still reachable via Alt+drag on hub, or near rim).
	if _is_physical_view() and not hit.is_empty():
		var port_phys := _port_at_screen(screen_pos, "", "", _port_grab_radius())
		if not port_phys.is_empty() and bool(port_phys.get("hub", false)) and (
				Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META)):
			_begin_hub_port_drag(port_phys)
			_touch_interaction = "hub_port"
			return
		if port_phys.is_empty() or _physical_prefer_body(screen_pos, hit):
			_begin_item_press(screen_pos, hit)
			return
		_start_wire_drag(port_phys)
		_touch_interaction = "wire"
		return

	var port := _port_at_screen(screen_pos, "", "", _port_grab_radius())
	if not port.is_empty():
		# Alt+drag (or Shift+Alt) on a hub port rotates it around the perimeter.
		if bool(port.get("hub", false)) and (
				Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META)):
			_begin_hub_port_drag(port)
			_touch_interaction = "hub_port"
			return
		_start_wire_drag(port)
		_touch_interaction = "wire"
		return

	if hit.is_empty():
		_marquee_selecting = true
		_marquee_start = screen_pos
		_marquee_end = screen_pos
		_touch_interaction = "marquee"
		return

	_begin_item_press(screen_pos, hit)


## True when the click is closer to the body center than to the rim (ports).
func _physical_prefer_body(screen_pos: Vector2, item: Dictionary) -> bool:
	var hit := _item_hit_rect(item)
	# Array bus ports sit on the bottom edge — keep most of the footprint as
	# drag/resize so clicks aren't swallowed into wire-drag.
	var rim := maxf(4.0, minf(hit.size.x, hit.size.y) * 0.16)
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(item.get("type", "")) == "compound" \
			and str(specs.get("compound_kind", "")) == "array":
		rim = maxf(rim, minf(10.0, hit.size.y * 0.22))
	var body := hit.grow(-rim)
	if body.size.x < 8.0 or body.size.y < 8.0:
		return true
	return body.has_point(screen_pos)


func _begin_hub_port_drag(port: Dictionary) -> void:
	_hub_port_dragging = true
	_hub_port_item_id = str(port.get("item_id", ""))
	_hub_port_handle_id = str(port.get("handle_id", ""))
	# Ensure handles are persisted before rotating.
	if model == null:
		return
	var item := model.get_item(_hub_port_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var kind := ""
	if str(item.get("type", "")) == "catchment":
		kind = PbiBiomass.catchment_output_kind(specs)
	else:
		ResourceKinds.new().migrate_resource_specs(specs)
		kind = str(specs.get("resource_kind", "water"))
	GraphHubPorts.ensure_hub_handles(item, kind)
	model.update_item(_hub_port_item_id, {"handles": item.get("handles", [])})
	queue_redraw()


func _on_hub_port_drag_move(screen_pos: Vector2) -> void:
	if model == null or _hub_port_item_id.is_empty():
		return
	var item := model.get_item(_hub_port_item_id)
	if item.is_empty():
		return
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var ang := GraphHubPorts.angle_from_center_to_point(
		GraphHubPorts.circle_center(tl, sz), screen_pos)
	if GraphHubPorts.set_handle_angle(item, _hub_port_handle_id, ang):
		model.update_item(_hub_port_item_id, {"handles": item.get("handles", [])})
		queue_redraw()


func _end_hub_port_drag() -> void:
	if _hub_port_dragging:
		layout_changed.emit()
	_hub_port_dragging = false
	_hub_port_item_id = ""
	_hub_port_handle_id = ""
	_touch_interaction = ""
	queue_redraw()


func _begin_item_press(screen_pos: Vector2, hit: Dictionary) -> void:
	var hit_id: String = hit.get("id", "") as String
	if Input.is_key_pressed(KEY_SHIFT):
		if selected_item_ids.has(hit_id):
			selected_item_ids.erase(hit_id)
		else:
			selected_item_ids.append(hit_id)
		if selected_item_ids.size() == 1:
			_select_item(selected_item_ids[0])
		else:
			selected_item_id = ""
			selected_connection_id = ""
			items_multi_selected.emit(selected_item_ids.duplicate())
			queue_redraw()
		return
	_item_dragging       = true
	_item_drag_duplicated = false
	_item_drag_id        = hit_id
	_item_drag_start_px  = screen_pos
	_item_drag_ids.clear()
	_item_drag_start_map.clear()
	_item_drag_start_elev.clear()
	if not selected_item_ids.has(hit_id):
		selected_item_ids.clear()
		selected_item_ids.append(hit_id)
	_item_drag_ids = selected_item_ids.duplicate()
	for iid: String in _item_drag_ids:
		var it := model.get_item(iid)
		if it.is_empty():
			continue
		if _is_physical_view() and GraphSiteLayout.has_site_coords(it):
			_item_drag_start_map[iid] = GraphSiteLayout.site_xz(it)
			_item_drag_start_elev[iid] = _elevation_m_for_item(it)
		elif _is_physical_view():
			# Unplaced → start at null sentinel; first move assigns site coords.
			_item_drag_start_map[iid] = Vector2(NAN, NAN)
			_item_drag_start_elev[iid] = _elevation_datum_m()
		else:
			_item_drag_start_map[iid] = Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0)))
	_item_drag_start_pos = _item_drag_start_map.get(hit_id, Vector2(float(hit.get("x", 0.0)), float(hit.get("y", 0.0))))
	_touch_interaction = "item"
	_select_item(hit_id)


func _touch_point_in_item_body(screen_pos: Vector2, item: Dictionary) -> bool:
	var rect := _item_hit_rect(item)
	if not rect.has_point(screen_pos):
		return false
	var itype := str(item.get("type", ""))
	var inset_x := TOUCH_LOAD_BODY_INSET_X if itype in ["appliance", "acload"] else TOUCH_BODY_INSET
	var inset_y := TOUCH_LOAD_BODY_INSET_Y if itype in ["appliance", "acload"] else TOUCH_BODY_INSET
	inset_x = minf(inset_x, rect.size.x * 0.38)
	inset_y = minf(inset_y, rect.size.y * 0.38)
	var inner := Rect2(
		rect.position + Vector2(inset_x, inset_y),
		rect.size - Vector2(inset_x * 2.0, inset_y * 2.0)
	)
	if inner.size.x < 16.0 or inner.size.y < 16.0:
		return true
	return inner.has_point(screen_pos)


# Left-button release: finalise wire/item drag or treat as click.
func _on_lmb_release(screen_pos: Vector2) -> void:
	if _resize_dragging:
		_end_resize_drag()
		return
	if _hub_port_dragging:
		_end_hub_port_drag()
		return
	if _ortho_seg_dragging:
		_ortho_seg_dragging = false
		_ortho_seg_drag_conn = ""
		_ortho_seg_drag_idx = -1
		_ortho_drag_poly_start = PackedVector2Array()
		_touch_interaction = ""
		queue_redraw()
		return
	if _waypoint_dragging:
		_waypoint_dragging = false
		_waypoint_drag_conn = ""
		_waypoint_drag_idx = -1
		_touch_interaction = ""
		queue_redraw()
		return
	if _wire_dragging:
		if (_wire_snap_valid and not _wire_snap.is_empty()) \
				or (_wire_snap_valid and not _wire_hub_drop.is_empty()):
			_finalize_connection()
		elif _wire_src_polarity == "resource" and _wire_snap.is_empty() \
				and _wire_hub_drop.is_empty() \
				and screen_pos.distance_to(_wire_src_pos) >= _effective_drag_threshold():
			_spawn_container_from_port_drag(screen_pos)
		_wire_dragging   = false
		_wire_snap       = {}
		_wire_snap_valid = false
		_wire_hub_drop   = {}
		queue_redraw()
		return

	if _item_dragging:
		var dist := screen_pos.distance_to(_item_drag_start_px)
		var moved := dist >= _effective_drag_threshold()
		var drag_id := _item_drag_id
		var drag_ids := _item_drag_ids.duplicate()
		if not moved:
			if selected_item_ids.size() <= 1 and not drag_id.is_empty():
				if _touch_input_active():
					_try_emit_touch_double_tap(screen_pos, drag_id)
				else:
					_select_item(drag_id)
		else:
			if drag_ids.size() == 1 and not drag_id.is_empty():
				_try_merge_resource_containers_on_drop(drag_id, screen_pos)
			layout_changed.emit()
		_item_dragging = false
		_item_drag_id  = ""
		_item_drag_ids.clear()
		_item_drag_start_map.clear()
		return

	if _marquee_selecting:
		_marquee_selecting = false
		_marquee_end = screen_pos
		var rect := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
		if rect.size.length() < 6.0:
			queue_redraw()
			# Treat tiny marquee as a normal click for deselect behavior
		else:
			var hits: Array[String] = []
			for item: Dictionary in _visible_items():
				if rect.intersects(_item_hit_rect(item)):
					hits.append(item.get("id", "") as String)
			if Input.is_key_pressed(KEY_SHIFT):
				for hid: String in hits:
					if not selected_item_ids.has(hid):
						selected_item_ids.append(hid)
			else:
				selected_item_ids.clear()
				for hid2: String in hits:
					selected_item_ids.append(hid2)
			if selected_item_ids.size() == 1:
				_select_item(selected_item_ids[0])
			elif selected_item_ids.size() > 1:
				selected_item_id = ""
				selected_connection_id = ""
				items_multi_selected.emit(selected_item_ids.duplicate())
				queue_redraw()
			else:
				var center := size * 0.5
				var conn_hits: Array[String] = []
				for conn: Dictionary in _visible_connections():
					if _connection_intersects_rect(conn, rect, center):
						conn_hits.append(conn.get("id", "") as String)
				if conn_hits.size() > 0:
					_select_connection(conn_hits[0])
				else:
					_select_item("")
		return

	# Click on background — check wires, then deselect
	if _item_at_screen(screen_pos).is_empty():
		var conn := _connection_at_screen(screen_pos)
		if not conn.is_empty():
			_select_connection(conn.get("id", "") as String)
		else:
			if view_mode == GraphSiteLayout.VIEW_SITE and not site_designate_mode.is_empty():
				site_background_clicked.emit(screen_pos)
			_select_item("")


# Item drag move
func _on_item_drag_move(screen_pos: Vector2) -> void:
	if model == null or _item_drag_id.is_empty():
		return
		
	if not _item_drag_duplicated and (Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)):
		var delta_px := screen_pos - _item_drag_start_px
		if delta_px.length() >= _effective_drag_threshold():
			_item_drag_duplicated = true
			_duplicate_dragged_items()
			
	var delta_px  := screen_pos - _item_drag_start_px
	if view_mode == GraphSiteLayout.VIEW_SITE:
		_on_site_item_drag_move(screen_pos, delta_px)
		return
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		_on_elevation_item_drag_move(screen_pos, delta_px)
		return
	var delta_gr  := delta_px / _zoom
	for iid: String in _item_drag_ids:
		var start_pos: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var new_pos := start_pos + delta_gr
		model.update_item(iid, {"x": new_pos.x, "y": new_pos.y})
	queue_redraw()


func _soi_radius_m() -> float:
	var disc := get_soi_disc_layout()
	return float(disc.get("radius_m", 150.0))


func _on_site_item_drag_move(screen_pos: Vector2, delta_px: Vector2) -> void:
	var s := GraphSiteLayout.px_per_m(_zoom)
	var delta_m := delta_px / s
	var r_m := _soi_radius_m()
	var disc_o := _disc_origin_screen()
	for iid: String in _item_drag_ids:
		var start_pos: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var new_xz: Vector2
		if is_nan(start_pos.x):
			# Dropping from unplaced tray onto the disc.
			new_xz = GraphSiteLayout.screen_to_site_m(screen_pos, disc_o, _zoom)
		else:
			new_xz = start_pos + delta_m
		new_xz = GraphSiteLayout.clamp_to_soi(new_xz, r_m)
		model.update_item(iid, {"site_x_m": new_xz.x, "site_z_m": new_xz.y})
	queue_redraw()


func _on_elevation_item_drag_move(screen_pos: Vector2, delta_px: Vector2) -> void:
	# Horizontal → along-section site metres; vertical → elevation_m (screen-up = +Y).
	var s := GraphSiteLayout.px_per_m(_zoom)
	var ex := maxf(elevation_exaggeration, 0.001)
	var r_m := _soi_radius_m()
	var disc_o := _disc_origin_screen()
	for iid: String in _item_drag_ids:
		var start_xz: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var along_m: float
		var cross_m: float
		var elev_m: float
		if is_nan(start_xz.x):
			# Dropping from unplaced tray — seat under the pointer.
			along_m = (screen_pos.x - disc_o.x) / s
			cross_m = 0.0
			elev_m = _elevation_datum_m() - (screen_pos.y - disc_o.y) / (s * ex)
		else:
			var proj0 := GraphSiteLayout.project_onto_section(start_xz, elevation_heading_rad)
			along_m = proj0.x + delta_px.x / s
			cross_m = proj0.y
			var start_elev: float = float(_item_drag_start_elev.get(iid, _elevation_datum_m()))
			elev_m = start_elev - delta_px.y / (s * ex)
		var site := GraphSiteLayout.section_to_site(along_m, cross_m, elevation_heading_rad)
		site = GraphSiteLayout.clamp_to_soi(site, r_m)
		model.update_item(iid, {
			"site_x_m": site.x,
			"site_z_m": site.y,
			"elevation_m": elev_m,
		})
	queue_redraw()


# ---------------------------------------------------------------------------
# Resize handles (freeform → width/height; site/elevation → footprint_*_m)
# ---------------------------------------------------------------------------

func _item_is_circular(item: Dictionary) -> bool:
	# Physical plan chips: circular resize for circular symbols only.
	if _is_physical_view():
		return GraphSiteLayout.uses_circular_plan_chip(item)
	return GraphSiteLayout.is_circular_node(str(item.get("type", "")))


func _resize_handle_center(item: Dictionary) -> Vector2:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	if _item_is_circular(item):
		# Invisible right-side handle at the equator of the circle / rect.
		return Vector2(tl.x + sz.x, tl.y + sz.y * 0.5)
	return tl + sz  # bottom-right corner


func _resize_handle_hit_rect(item: Dictionary) -> Rect2:
	var c := _resize_handle_center(item)
	var pad := RESIZE_HIT_PAD
	return Rect2(c - Vector2(pad, pad), Vector2(pad * 2.0, pad * 2.0))


func _resize_handle_item_at(screen_pos: Vector2) -> String:
	if model == null:
		return ""
	# Prefer the primary selected item, then any selected.
	var candidates: Array[String] = []
	if not selected_item_id.is_empty():
		candidates.append(selected_item_id)
	for iid: String in selected_item_ids:
		if not candidates.has(iid):
			candidates.append(iid)
	for iid2: String in candidates:
		var it := model.get_item(iid2)
		if it.is_empty():
			continue
		if _resize_handle_hit_rect(it).has_point(screen_pos):
			return iid2
	return ""


func _begin_resize_drag(item_id: String, screen_pos: Vector2) -> void:
	var item := model.get_item(item_id)
	if item.is_empty():
		return
	_resize_dragging = true
	_resize_item_id = item_id
	_resize_start_screen = screen_pos
	_resize_circular = _item_is_circular(item)
	_select_item(item_id)
	if _is_physical_view():
		_resize_start_size = GraphSiteLayout.physical_footprint_m(item)
	else:
		_resize_start_size = Vector2(
			float(item.get("width", default_width(str(item.get("type", ""))))),
			float(item.get("height", default_height(str(item.get("type", ""))))))
	_touch_interaction = "resize"
	queue_redraw()


func _on_resize_drag_move(screen_pos: Vector2) -> void:
	if model == null or _resize_item_id.is_empty():
		return
	var item := model.get_item(_resize_item_id)
	if item.is_empty():
		return
	var delta := screen_pos - _resize_start_screen
	if _is_physical_view():
		var s := GraphSiteLayout.px_per_m(_zoom)
		var d_m := delta / maxf(s, 0.001)
		var fp: Vector2
		if _resize_circular:
			# Uniform scale from right-edge pull (use X delta).
			var d := d_m.x
			var side := maxf(_resize_start_size.x + d, 0.5)
			fp = GraphSiteLayout.clamp_footprint_m(Vector2(side, side))
		else:
			fp = GraphSiteLayout.clamp_footprint_m(Vector2(
				_resize_start_size.x + d_m.x,
				_resize_start_size.y + d_m.y))
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		specs["footprint_w_m"] = fp.x
		specs["footprint_d_m"] = fp.y
		model.update_item(_resize_item_id, {"specs": specs})
	else:
		# Freeform: graph-space px; do NOT touch site footprint keys.
		var d_g := delta / maxf(_zoom, 0.001)
		var nw: float
		var nh: float
		if _resize_circular:
			nw = maxf(_resize_start_size.x + d_g.x, 48.0)
			nh = nw
		else:
			nw = maxf(_resize_start_size.x + d_g.x, 48.0)
			nh = maxf(_resize_start_size.y + d_g.y, 36.0)
		model.update_item(_resize_item_id, {"width": nw, "height": nh})
	queue_redraw()


func _end_resize_drag() -> void:
	if _resize_dragging:
		layout_changed.emit()
	_resize_dragging = false
	_resize_item_id = ""
	_touch_interaction = ""
	queue_redraw()


func _draw_resize_handle(item: Dictionary) -> void:
	var iid := str(item.get("id", ""))
	if iid.is_empty():
		return
	if iid != selected_item_id and not selected_item_ids.has(iid):
		return
	var c := _resize_handle_center(item)
	var hs := RESIZE_HANDLE_PX
	if _item_is_circular(item):
		# Subtle right-edge grip (mostly invisible until hover/select).
		var grip := Rect2(c.x - 2.0, c.y - hs, 4.0, hs * 2.0)
		draw_rect(grip, Color(0.85, 0.95, 1.0, 0.55), true)
		draw_rect(grip, Color(0.35, 0.75, 1.0, 0.9), false, 1.0)
	else:
		var r := Rect2(c - Vector2(hs, hs), Vector2(hs, hs))
		draw_rect(r, Color(0.2, 0.55, 0.95, 0.95), true)
		draw_rect(r, Color(1.0, 1.0, 1.0, 0.85), false, 1.0)
		# Corner accent lines
		draw_line(c + Vector2(-hs + 2.0, 0.0), c + Vector2(0.0, 0.0), Color(1, 1, 1, 0.7), 1.5)
		draw_line(c + Vector2(0.0, -hs + 2.0), c + Vector2(0.0, 0.0), Color(1, 1, 1, 0.7), 1.5)


func _duplicate_dragged_items() -> void:
	if model == null:
		return
		
	var new_drag_ids: Array[String] = []
	var new_drag_start_map := {}
	var new_drag_start_elev := {}
	var new_drag_id := ""
	
	# Mapping from old IDs to new IDs
	var old_to_new_id_map := {}
	
	for iid in _item_drag_ids:
		var orig := model.get_item(iid)
		if orig.is_empty():
			continue
		var copy := orig.duplicate(true)
		var new_id := model.generate_item_id()
		copy["id"] = new_id
		old_to_new_id_map[iid] = new_id
		
		# Suffix the name of the copied item if it exists
		var specs: Dictionary = copy.get("specs", {})
		if specs.has("name"):
			specs["name"] = str(specs["name"]) + " (Copy)"
			
		model.add_item(copy)
		
		new_drag_ids.append(new_id)
		new_drag_start_map[new_id] = _item_drag_start_map.get(iid, Vector2.ZERO)
		new_drag_start_elev[new_id] = _item_drag_start_elev.get(iid, _elevation_datum_m())
		
		if iid == _item_drag_id:
			new_drag_id = new_id
			
	# Find and duplicate connections between the dragged items
	var conns_to_add: Array[Dictionary] = []
	for conn in model.connections:
		var sid := str(conn.get("source_item_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		if old_to_new_id_map.has(sid) and old_to_new_id_map.has(tid):
			var conn_copy: Dictionary = conn.duplicate(true) as Dictionary
			conn_copy["id"] = model.generate_connection_id()
			conn_copy["source_item_id"] = old_to_new_id_map[sid]
			conn_copy["target_item_id"] = old_to_new_id_map[tid]
			conns_to_add.append(conn_copy)
			
	for new_conn in conns_to_add:
		model.add_connection(new_conn)
			
	_item_drag_ids = new_drag_ids
	_item_drag_start_map = new_drag_start_map
	_item_drag_start_elev = new_drag_start_elev
	_item_drag_id = new_drag_id
	
	selected_item_ids = new_drag_ids.duplicate()
	if new_drag_ids.size() == 1:
		_select_item(new_drag_id)
	else:
		selected_item_id = ""
		selected_connection_id = ""
		items_multi_selected.emit(new_drag_ids.duplicate())


## Drop one resource tank onto another of the same kind → single merged container.
func _try_merge_resource_containers_on_drop(dragged_id: String, screen_pos: Vector2) -> bool:
	if model == null or dragged_id.is_empty():
		return false
	var dragged := model.get_item(dragged_id)
	if dragged.is_empty() or str(dragged.get("type", "")) != "resource":
		return false
	var target := _item_at_screen_excluding(screen_pos, dragged_id)
	if target.is_empty():
		return false
	if str(target.get("type", "")) != "resource":
		return false
	if str(dragged.get("scope_id", "root")) != str(target.get("scope_id", "root")):
		return false
	var d_specs: Dictionary = (dragged.get("specs", {}) as Dictionary).duplicate(true)
	var t_specs: Dictionary = (target.get("specs", {}) as Dictionary).duplicate(true)
	ResourceKinds.new().migrate_resource_specs(d_specs)
	ResourceKinds.new().migrate_resource_specs(t_specs)
	var d_kind := ResourceKinds.normalize_kind(str(d_specs.get("resource_kind", "")))
	var t_kind := ResourceKinds.normalize_kind(str(t_specs.get("resource_kind", "")))
	if d_kind.is_empty() or d_kind != t_kind:
		return false
	var d_cap := float(d_specs.get("capacity_qty", 0.0))
	var t_cap := float(t_specs.get("capacity_qty", 0.0))
	var d_unlim := bool(d_specs.get("unlimited_capacity", false))
	var t_unlim := bool(t_specs.get("unlimited_capacity", false))
	var d_neg := bool(d_specs.get("allow_negative", false))
	var t_neg := bool(t_specs.get("allow_negative", false))
	if d_cap <= 0.0 and t_cap <= 0.0 and not d_unlim and not t_unlim:
		return false
	var d_lvl := clampf(float(d_specs.get("level", 0.0)), 0.0, 1.0)
	var t_lvl := clampf(float(t_specs.get("level", 0.0)), 0.0, 1.0)
	var new_cap := d_cap + t_cap
	var new_lvl := (d_cap * d_lvl + t_cap * t_lvl) / new_cap if new_cap > 0.001 else 0.0
	var target_id := str(target.get("id", ""))
	var unit := str(t_specs.get("capacity_unit", ResourceKinds.default_unit(t_kind)))
	# Infinity / deficit flags OR across both parents — do not collapse an
	# unlimited tank into a finite sum of nominal capacity_qty alone.
	t_specs["unlimited_capacity"] = d_unlim or t_unlim
	t_specs["allow_negative"] = d_neg or t_neg
	if bool(t_specs["unlimited_capacity"]):
		# Keep a display nominal; survivor stays conceptual.
		t_specs["capacity_qty"] = maxf(maxf(d_cap, t_cap), 100.0)
		t_specs["level"] = clampf(new_lvl, 0.0, 1.0) if new_cap > 0.001 else t_lvl
	else:
		t_specs["capacity_qty"] = new_cap
		t_specs["level"] = clampf(new_lvl, 0.0, 1.0)
	t_specs["capacity"] = "%.0f %s" % [float(t_specs["capacity_qty"]), unit] if unit in ["L", "kg"] else "%.1f %s" % [float(t_specs["capacity_qty"]), unit]
	# Preserve scale/JIT flags if either parent had them on.
	if d_specs.has("scale_with_fill") or t_specs.has("scale_with_fill"):
		t_specs["scale_with_fill"] = bool(d_specs.get("scale_with_fill", true)) \
				and bool(t_specs.get("scale_with_fill", true))
	if bool(d_specs.get("jit_outflow", false)) or bool(t_specs.get("jit_outflow", false)):
		t_specs["jit_outflow"] = true
	# Rewire connections from absorbed tank → survivor (remove/add for handle bookkeeping).
	var to_rewire: Array = model.connections_for_item(dragged_id)
	for conn_v: Variant in to_rewire:
		var conn: Dictionary = conn_v as Dictionary
		var cid := str(conn.get("id", ""))
		if cid.is_empty():
			continue
		var fresh: Dictionary = conn.duplicate(true)
		model.remove_connection(cid)
		if str(fresh.get("source_item_id", "")) == dragged_id:
			fresh["source_item_id"] = target_id
		if str(fresh.get("target_item_id", "")) == dragged_id:
			fresh["target_item_id"] = target_id
		fresh.erase("id")
		model.add_connection(fresh)
	model.update_item(target_id, {"specs": t_specs})
	model.remove_item(dragged_id)
	_select_item(target_id)
	resource_containers_merged.emit(target_id, dragged_id, d_kind)
	queue_redraw()
	return true


func _item_at_screen_excluding(screen_pos: Vector2, exclude_id: String) -> Dictionary:
	if model == null:
		return {}
	var vis := _visible_items()
	for i in range(vis.size() - 1, -1, -1):
		var item: Dictionary = vis[i]
		if str(item.get("id", "")) == exclude_id:
			continue
		if _item_hit_rect(item).has_point(screen_pos):
			return item
	return {}


func _select_item(item_id: String) -> void:
	selected_item_id       = item_id
	selected_connection_id = ""
	selected_item_ids.clear()
	if not item_id.is_empty():
		selected_item_ids.append(item_id)
	item_selected.emit(item_id)
	queue_redraw()


# Returns the topmost item whose rect contains screen_pos, or {}
func _item_at_screen(screen_pos: Vector2) -> Dictionary:
	if model == null:
		return {}
	# Iterate in reverse so topmost (last drawn) is hit first
	var vis := _visible_items()
	for i in range(vis.size() - 1, -1, -1):
		var item: Dictionary = vis[i]
		if _item_hit_rect(item).has_point(screen_pos):
			return item
	return {}


func _select_connection(conn_id: String) -> void:
	selected_connection_id = conn_id
	selected_item_id       = ""
	selected_item_ids      = []
	connection_selected.emit(conn_id)
	queue_redraw()


# ---------------------------------------------------------------------------
# Wire drag — create connections by dragging from a port  (Phase 6)
# ---------------------------------------------------------------------------

func _port_grab_radius() -> float:
	var base := maxf(10.0, 9.0 * _zoom)
	if _touch_input_active() or DisplayServer.is_touchscreen_available():
		return maxf(base, TOUCH_PORT_GRAB_MIN)
	return base


func _port_hit_radius() -> float:
	return _port_grab_radius()


func _wire_snap_radius() -> float:
	var base := maxf(SNAP_RADIUS_PX, _port_grab_radius() + 6.0)
	if _touch_input_active() or DisplayServer.is_touchscreen_available():
		return maxf(base, TOUCH_SNAP_RADIUS_MIN)
	return base


## Incoming wire tangent at a port (reverse of outgoing handle tangent).
func _incoming_tangent(outgoing: Vector2) -> Vector2:
	return -outgoing


func _wire_spread(from: Vector2, to: Vector2) -> float:
	var dist := from.distance_to(to)
	return clampf(dist * 0.48, 48.0 * _zoom, 200.0 * _zoom)


func _screen_to_graph(screen_pos: Vector2) -> Vector2:
	var center := size * 0.5
	return (screen_pos - center - _pan) / maxf(_zoom, 0.001)


func _graph_to_screen(graph_pos: Vector2, center: Vector2) -> Vector2:
	return center + _pan + graph_pos * _zoom


## Label font size that scales with zoom (base/max are graph-space design px).
func _fit_font_size(inner: Rect2, lines: int = 1,
		base_graph_px: float = 11.0, max_graph_px: float = 13.0) -> int:
	return GraphNodeLabel.body_font_size(inner, lines, base_graph_px, max_graph_px, _zoom)


func _fit_stat_font_size(inner: Rect2, max_graph_px: float = 20.0) -> int:
	return GraphNodeLabel.stat_font_size(inner, max_graph_px, _zoom)


func _fit_title_font_size(band_h: float) -> int:
	return GraphNodeLabel.title_font_size(band_h, _zoom)


func _title_band_height(node_screen_h: float) -> float:
	return GraphNodeLabel.title_band_height(node_screen_h, _zoom)


func _draw_fitted_label(pos: Vector2, text: String, max_w: float, fsize: int, color: Color) -> void:
	var fnt := ThemeDB.fallback_font
	var shown := GraphNodeLabel.ellipsis(fnt, text, max_w, fsize)
	draw_string(fnt, pos, shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, color)


func _wire_bezier_controls(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2, curve_tension: float = 1.0) -> Dictionary:
	if from.is_equal_approx(to):
		return {"c1": from, "c2": to}
		
	var spread := _wire_spread(from, to) * curve_tension
	
	var dir1 := from.direction_to(to)
	var t1 := from_tang
	var dot1 := t1.dot(dir1)
	if dot1 < 0.3:
		var blend := clampf((0.3 - dot1) / 1.3, 0.0, 1.0)
		t1 = t1.lerp(dir1, blend).normalized()
		
	var dir2 := to.direction_to(from)
	var t2 := to_tang_in
	var dot2 := t2.dot(dir2)
	if dot2 < 0.3:
		var blend := clampf((0.3 - dot2) / 1.3, 0.0, 1.0)
		t2 = t2.lerp(dir2, blend).normalized()

	return {
		"c1": from + t1 * spread,
		"c2": to + t2 * spread,
	}


func _conn_curve_tension(conn: Dictionary) -> float:
	return clampf(float(conn.get("curve_tension", 1.0)), 0.15, 2.5)


func _conn_corner_radius_graph(conn: Dictionary) -> float:
	return clampf(float(conn.get("corner_radius", 28.0)), 4.0, 120.0)


func _waypoints_graph(conn: Dictionary) -> Array:
	var out: Array = []
	for wp: Variant in conn.get("waypoints", []) as Array:
		if wp is Vector2:
			out.append(wp)
		elif wp is Dictionary:
			out.append(Vector2(float(wp.get("x", 0.0)), float(wp.get("y", 0.0))))
	return out


func _set_waypoints_graph(conn_id: String, wps: Array) -> void:
	if model == null:
		return
	var stored: Array = []
	for wp: Variant in wps:
		if wp is Vector2:
			stored.append({"x": (wp as Vector2).x, "y": (wp as Vector2).y})
	model.update_connection(conn_id, {"waypoints": stored})


func _waypoints_screen(conn: Dictionary, center: Vector2) -> Array:
	var out: Array = []
	for wp: Variant in conn.get("waypoints", []) as Array:
		if wp is Vector2:
			out.append(_graph_to_screen(wp as Vector2, center))
		elif wp is Dictionary:
			out.append(_graph_to_screen(
				Vector2(float(wp.get("x", 0.0)), float(wp.get("y", 0.0))), center))
	return out


func _wire_color_for_connection(conn: Dictionary, polarity: String) -> Color:
	if polarity == "resource":
		return ResourceKinds.wire_color(str(conn.get("resource_type", "")))
	return PORT_COLORS.get(polarity, C_BORDER) as Color


func _wire_color_for_port(polarity: String, resource_kind: String = "") -> Color:
	if polarity == "resource":
		return ResourceKinds.wire_color(resource_kind)
	return PORT_COLORS.get(polarity, C_BORDER) as Color


## Dynamic port list from item specs (multi-I/O processors, typed resource tanks).
func _resolved_handles(item: Dictionary) -> Array:
	# Solar-array compounds draw ONE +/- bus pair on the bottom edge
	# (see _draw_array_compound_handles). Return the same handles here so that
	# hit-testing / wire-snapping / connection routing all agree with what's
	# drawn — otherwise the grabbable ports sit on the side edges (generic
	# compound AC/DC) and the visible bottom dots can't be grabbed.
	if str(item.get("type", "")) == "compound" \
			and str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) == "array" \
			and (item.get("handles", []) as Array).is_empty():
		return GraphArrayLayout.default_handles()
	return GraphPortService.resolved_handles(item, HANDLES)


func _handle_dict(item: Dictionary, handle_id: String) -> Dictionary:
	for h: Dictionary in _resolved_handles(item):
		if str(h.get("id", "")) == handle_id:
			return h
	return {}


func _resource_kind_for_port(item_id: String, handle_id: String) -> String:
	if model == null:
		return ""
	var item := model.get_item(item_id)
	if item.is_empty():
		return ""
	var h := _handle_dict(item, handle_id)
	return str(h.get("resource_kind", ""))


func _start_wire_drag(port: Dictionary) -> void:
	_wire_dragging      = true
	_wire_src_item_id   = port.get("item_id",   "") as String
	_wire_src_handle_id = port.get("handle_id", "") as String
	_wire_src_polarity  = port.get("polarity",  "positive") as String
	_wire_src_resource_kind = str(port.get("resource_kind", ""))
	_wire_src_pos       = port.get("pos",       Vector2.ZERO) as Vector2
	_wire_src_tangent   = port.get("tangent",   Vector2.RIGHT) as Vector2
	_wire_cursor_pos    = _wire_src_pos
	_wire_snap          = {}
	_wire_snap_valid    = false
	_wire_hub_drop      = {}


func _on_wire_drag_move(screen_pos: Vector2) -> void:
	_wire_cursor_pos = screen_pos
	_wire_snap = _port_at_screen(screen_pos,
		_wire_src_item_id, _wire_src_handle_id, _wire_snap_radius())
	_wire_snap_valid = (not _wire_snap.is_empty()) and \
		_polarity_compatible(
			_wire_src_polarity,
			_wire_snap.get("polarity", "") as String,
			_wire_src_resource_kind,
			str(_wire_snap.get("resource_kind", "")))
	_wire_hub_drop = {}
	# Drop-to-body: resource wire released inside a hub circle (no port hit).
	if not _wire_snap_valid and _wire_src_polarity == "resource":
		_wire_hub_drop = _hub_body_at_screen(screen_pos, _wire_src_item_id)
		if not _wire_hub_drop.is_empty():
			var drop_kind := str(_wire_hub_drop.get("kind", ""))
			if ResourceKinds.connection_allowed(_wire_src_resource_kind, drop_kind):
				_wire_snap_valid = true
			else:
				_wire_hub_drop = {}
	queue_redraw()


## Hub tank under cursor for drop-to-body connect. Returns {item_id, kind, angle_rad}.
func _hub_body_at_screen(screen_pos: Vector2, skip_item: String) -> Dictionary:
	if model == null:
		return {}
	var center := size * 0.5
	for item: Dictionary in _visible_items():
		var iid := str(item.get("id", ""))
		if iid == skip_item:
			continue
		if not GraphHubPorts.is_hub_type(str(item.get("type", ""))):
			continue
		# Drop-to-body on resource tanks and catchments (PBI → catchment).
		var ity := str(item.get("type", ""))
		if ity != "resource" and ity != "catchment":
			continue
		var tl := _item_screen_tl(item, center)
		var sz := _item_screen_size(item)
		if not GraphHubPorts.point_in_hub_body(tl, sz, screen_pos):
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var kind := ""
		if ity == "catchment":
			kind = PbiBiomass.catchment_output_kind(specs)
		else:
			ResourceKinds.new().migrate_resource_specs(specs)
			kind = str(specs.get("resource_kind", "water"))
		var ang := GraphHubPorts.angle_from_center_to_point(
			GraphHubPorts.circle_center(tl, sz), screen_pos)
		return {"item_id": iid, "kind": kind, "angle_rad": ang}
	return {}


func _finalize_connection() -> void:
	if model == null:
		return
	# Drop-to-body hub connect (no discrete port snap).
	if not _wire_hub_drop.is_empty() and _wire_snap_valid:
		_finalize_hub_drop_connection()
		return
	if _wire_snap.is_empty() or not _wire_snap_valid:
		return
	var tgt_kind := str(_wire_snap.get("resource_kind", ""))
	var res_type := ""
	if _wire_src_polarity == "resource":
		res_type = ResourceKinds.normalize_kind(_wire_src_resource_kind)
	var type_mismatch := _wire_src_polarity == "resource" \
		and not ResourceKinds.kinds_compatible(_wire_src_resource_kind, tgt_kind)
	model.add_connection({
		"scope_id":         active_scope_id,
		"polarity":         _wire_src_polarity,
		"resource_type":    res_type if _wire_src_polarity == "resource" else "",
		"source_item_id":   _wire_src_item_id,
		"source_handle_id": _wire_src_handle_id,
		"target_item_id":   _wire_snap.get("item_id",   "") as String,
		"target_handle_id": _wire_snap.get("handle_id", "") as String,
		"waypoints":        [],
		"route_3d":         [],
		"conduit_type":     "",
		"route_length_m":   0.0,
		"line_style":       model.last_line_style,
		"curve_tension":    1.0,
		"corner_radius":    28.0,
		"voltage_mismatch": false,
		"type_mismatch":    type_mismatch,
	})


func _finalize_hub_drop_connection() -> void:
	var tgt_id := str(_wire_hub_drop.get("item_id", ""))
	var kind := ResourceKinds.normalize_kind(str(_wire_hub_drop.get("kind", "")))
	var ang := float(_wire_hub_drop.get("angle_rad", 0.0))
	if tgt_id.is_empty() or model == null:
		return
	var item := model.get_item(tgt_id)
	if item.is_empty():
		return
	# Wire ends on tank → "in" port; if somehow starting from tank body, "out".
	var role := GraphHubPorts.ROLE_IN
	var wired := _wired_handle_ids(tgt_id)
	var port := GraphHubPorts.acquire_hub_port(item, kind, ang, role, wired)
	# Persist handles on the item (acquire mutates item.handles).
	model.update_item(tgt_id, {"handles": item.get("handles", [])})
	var res_type := ResourceKinds.normalize_kind(_wire_src_resource_kind)
	model.add_connection({
		"scope_id":         active_scope_id,
		"polarity":         "resource",
		"resource_type":    res_type,
		"source_item_id":   _wire_src_item_id,
		"source_handle_id": _wire_src_handle_id,
		"target_item_id":   tgt_id,
		"target_handle_id": str(port.get("id", "")),
		"waypoints":        [],
		"route_3d":         [],
		"conduit_type":     "",
		"route_length_m":   0.0,
		"line_style":       model.last_line_style,
		"curve_tension":    1.0,
		"corner_radius":    28.0,
		"voltage_mismatch": false,
		"type_mismatch":    not ResourceKinds.kinds_compatible(_wire_src_resource_kind, kind),
	})
	_wire_hub_drop = {}
	layout_changed.emit()
	queue_redraw()


## True when a resource handle id is a consuming (input) port, as opposed to
## a producing (output) port — mirrors the id conventions used by static
## HANDLES, GraphPortService's dynamic res_in_/res_out_ ports, and hub ports.
func _resource_port_is_input(handle_id: String) -> bool:
	return handle_id == "input" \
		or handle_id.begins_with("res_in_") \
		or handle_id.begins_with("hub_in_")


## Releasing a resource wire on empty canvas space spawns a new container
## node pre-wired to the source port, instead of discarding the drag. Input
## ports get a supply tank (unlimited + can run into deficit, so it never
## blocks the consumer); output ports get an unlimited sink (never fills up
## and blocks the producer) — same defaults as the inspector's "No capacity
## limit" toggle (see ResourceKinds.migrate_resource_specs).
func _spawn_container_from_port_drag(screen_pos: Vector2) -> void:
	if model == null or _wire_src_item_id.is_empty():
		return
	var kind := ResourceKinds.normalize_kind(_wire_src_resource_kind)
	if kind.is_empty():
		return
	var is_input := _resource_port_is_input(_wire_src_handle_id)
	var graph_pos := _screen_to_graph(screen_pos)
	var w := 110.0
	var h := 96.0
	var item_id := model.generate_item_id()
	var specs := {
		"name": "%s %s" % [ResourceKinds.display_name(kind), "Supply" if is_input else "Store"],
		"resource_kind": kind,
		"capacity_qty": 100.0,
		"capacity_unit": ResourceKinds.default_unit(kind),
		"level": 0.5 if is_input else 0.0,
		"unlimited_capacity": true,
		"allow_negative": is_input,
		"alert_threshold_pct": 95.0,
		"cost": 0.0,
	}
	model.add_item({
		"id":       item_id,
		"type":     "resource",
		"x":        graph_pos.x - w * 0.5,
		"y":        graph_pos.y - h * 0.5,
		"width":    w,
		"height":   h,
		"scope_id": active_scope_id,
		"specs":    specs,
	})
	var conn := {
		"scope_id":         active_scope_id,
		"polarity":         "resource",
		"resource_type":    kind,
		"waypoints":        [],
		"route_3d":         [],
		"conduit_type":     "",
		"route_length_m":   0.0,
		"line_style":       model.last_line_style,
		"curve_tension":    1.0,
		"corner_radius":    28.0,
		"voltage_mismatch": false,
		"type_mismatch":    false,
	}
	if is_input:
		conn["source_item_id"]   = item_id
		conn["source_handle_id"] = "output"
		conn["target_item_id"]   = _wire_src_item_id
		conn["target_handle_id"] = _wire_src_handle_id
	else:
		conn["source_item_id"]   = _wire_src_item_id
		conn["source_handle_id"] = _wire_src_handle_id
		conn["target_item_id"]   = item_id
		conn["target_handle_id"] = "input"
	model.add_connection(conn)
	layout_changed.emit()


## Returns info for all handles on an item as an Array of Dictionaries.
func _get_all_handle_infos(item: Dictionary, center: Vector2) -> Array:
	var result: Array = []
	var tl    := _item_screen_tl(item, center)
	var sz    := _item_screen_size(item)
	var itype := item.get("type", "generic") as String
	var iw    := float(item.get("width",  120.0))
	var ih    := float(item.get("height",  90.0))
	var hub := GraphHubPorts.is_hub_type(itype)

	var handles: Array = _resolved_handles(item)

	for h: Dictionary in handles:
		var hid := str(h.get("id", ""))
		var pol := h.get("polarity", "positive") as String
		var rk := str(h.get("resource_kind", ""))
		if hub and h.has("angle_rad"):
			var ang := float(h.get("angle_rad", 0.0))
			result.append({
				"item_id":   item.get("id", "") as String,
				"handle_id": hid,
				"polarity":  pol,
				"resource_kind": rk,
				"pos":       GraphHubPorts.screen_pos_on_circle(tl, sz, ang),
				"tangent":   GraphHubPorts.outward_tangent(ang),
				"angle_rad": ang,
				"hub":       true,
			})
			continue
		var rx: float
		var ry: float
		if h.has("rx"):
			rx = float(h["rx"])
			ry = float(h["ry"])
		else:
			rx = float(h.get("x", 0.0)) / maxf(1.0, iw)
			ry = float(h.get("y", 0.0)) / maxf(1.0, ih)
		result.append({
			"item_id":   item.get("id",        "") as String,
			"handle_id": hid,
			"polarity":  pol,
			"resource_kind": rk,
			"pos":       tl + Vector2(sz.x * rx, sz.y * ry),
			"tangent":   _tangent_from_rx_ry(rx, ry),
			"hub":       false,
		})
	return result


## Handles that are visible and interactive — matches _draw_item_handles filtering.
func _get_interactive_handle_infos(item: Dictionary, center: Vector2) -> Array:
	var all := _get_all_handle_infos(item, center)
	var itype := item.get("type", "generic") as String
	# Array compounds expose exactly the two bus ports from _resolved_handles;
	# they must all stay interactive (the generic "compound" primary filter would
	# otherwise drop them since their ids are "positive"/"negative").
	if itype == "compound" \
			and str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) == "array":
		return all
	var primary: Array = _PRIMARY_HANDLES.get(itype, []) as Array
	if primary.is_empty():
		return all
	var wired := _wired_handle_ids(item.get("id", "") as String)
	var out: Array = []
	for h: Dictionary in all:
		var hid := h.get("handle_id", "") as String
		if primary.has(hid) or wired.has(hid) or hid.begins_with("res_in_") or hid.begins_with("res_out_"):
			out.append(h)
	return out


## Returns the nearest port within `radius` screen pixels, excluding one handle.
func _port_at_screen(screen_pos: Vector2,
		skip_item: String, skip_handle: String, radius: float) -> Dictionary:
	if model == null:
		return {}
	var center    := size * 0.5
	var best_dist := radius
	var best:       Dictionary = {}
	for item: Dictionary in _visible_items():
		for h: Dictionary in _get_interactive_handle_infos(item, center):
			if h["item_id"] == skip_item and h["handle_id"] == skip_handle:
				continue
			var d := (h["pos"] as Vector2).distance_to(screen_pos)
			if d < best_dist:
				best_dist = d
				best = h
	return best


## True when src and tgt polarities form a valid connection. Resource↔resource
## ports also allow a user override when kinds mismatch but share the same
## fundamental unit of measure (mass/volume/energy/…) — see
## ResourceKinds.connection_allowed.
func _polarity_compatible(src: String, tgt: String,
		src_kind: String = "", tgt_kind: String = "") -> bool:
	if src == "resource" and tgt == "resource":
		return ResourceKinds.connection_allowed(src_kind, tgt_kind)
	if src == tgt:
		return true
	# load ↔ ac (appliance into outlet)
	if src in ["load", "ac"] and tgt in ["load", "ac"]:
		return true
	# smart-battery ↔ DC positive (special controller input)
	if (src == "smart_battery" and tgt == "positive") \
			or (src == "positive" and tgt == "smart_battery"):
		return true
	return false


## True while the current wire-drag snap target is a resource port that only
## connects via the fundamental-unit override (kinds differ, dimension matches) —
## drives the amber "allowed but unusual" feedback instead of green/red.
func _wire_snap_is_kind_override() -> bool:
	if _wire_snap.is_empty() or not _wire_snap_valid or _wire_src_polarity != "resource":
		return false
	var tgt_kind := str(_wire_snap.get("resource_kind", ""))
	return not ResourceKinds.kinds_compatible(_wire_src_resource_kind, tgt_kind)


## Draws the dashed preview wire while a drag is in progress.
func _draw_temp_wire() -> void:
	if not _wire_dragging:
		return

	var col := _wire_color_for_port(_wire_src_polarity, _wire_src_resource_kind)
	var preview_width := 2.5
	if _wire_src_polarity == "resource":
		var stroke := ResourceEdgeVis.stroke_for(
			ResourceKinds.normalize_kind(_wire_src_resource_kind),
			0.0, false, false)
		col = stroke.get("color", col) as Color
		preview_width = float(stroke.get("width", 1.6))
	var snap_kind_override := _wire_snap_is_kind_override()
	if not _wire_snap.is_empty() and not _wire_snap_valid:
		col = C_RED
		preview_width = 2.0
	elif snap_kind_override:
		col = UITheme.C_WARN
		preview_width = 2.0

	var to_pos:  Vector2
	var to_tang_in: Vector2

	if not _wire_snap.is_empty():
		to_pos = _wire_snap.get("pos", Vector2.ZERO) as Vector2
		to_tang_in = _incoming_tangent(_wire_snap.get("tangent", Vector2.RIGHT) as Vector2)
	else:
		to_pos = _wire_cursor_pos
		to_tang_in = (_wire_src_pos - _wire_cursor_pos).normalized()

	var ctrl := _wire_bezier_controls(_wire_src_pos, _wire_src_tangent, to_pos, to_tang_in)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]

	if _wire_src_polarity == "resource":
		_draw_bezier_stroke(_wire_src_pos, c1, c2, to_pos, 28, col, preview_width)
		if not _wire_snap.is_empty() and _wire_snap_valid:
			ResourceEdgeVis.draw_bezier_flow_cues(
				self, _wire_src_pos, c1, c2, to_pos, col, preview_width, _flow_phase, false)
	else:
		# Dashed preview: draw only even-numbered segments
		var steps := 28
		var prev  := _wire_src_pos
		for i in range(1, steps + 1):
			var t := float(i) / float(steps)
			var p := _wire_src_pos.bezier_interpolate(c1, c2, to_pos, t)
			if i % 2 == 0:
				draw_line(prev, p, Color(col.r, col.g, col.b, 0.75), 2.5)
			prev = p

	# Source port pulse
	draw_circle(_wire_src_pos, 9.0 * _zoom,
		Color(col.r, col.g, col.b, 0.25))

	# Snap-target highlight
	if not _wire_snap.is_empty():
		var snap_pos := _wire_snap.get("pos", Vector2.ZERO) as Vector2
		var ring_col := C_RED
		if _wire_snap_valid:
			ring_col = UITheme.C_WARN if snap_kind_override else C_GREEN
		draw_circle(snap_pos, 10.0 * _zoom, Color(ring_col.r, ring_col.g, ring_col.b, 0.25))
		draw_circle(snap_pos, 9.0  * _zoom, ring_col, false)
		if (not _wire_snap_valid or snap_kind_override) and _wire_src_polarity == "resource":
			var msg := ResourceKinds.mismatch_message(
				_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
			var fnt := ThemeDB.fallback_font
			var msg_col := Color(0.98, 0.45, 0.42, 0.95) if not _wire_snap_valid else Color(0.98, 0.78, 0.35, 0.95)
			draw_string(fnt, snap_pos + Vector2(12.0, -8.0), msg,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, msg_col)


# ---------------------------------------------------------------------------
# Wire rendering  (Phase 5)
# ---------------------------------------------------------------------------


## Sum of virtual appliance / ac load + baseline demand (W).
## True when a load item is actively drawing power (on and watts > threshold).
func _is_load_group_item(it: Dictionary) -> bool:
	if str(it.get("type", "")) != "compound":
		return false
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	return str(sp.get("compound_kind", "")) == "load_group"


func _load_group_draw_w(it: Dictionary) -> float:
	if model == null:
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		return float(sp.get("avg_watts", sp.get("max_watts", 0.0)))
	var tree := get_tree()
	if tree == null:
		var sp2: Dictionary = it.get("specs", {}) as Dictionary
		return float(sp2.get("avg_watts", sp2.get("max_watts", 0.0)))
	return GraphAcLoad.sum_load_group_watts(model, it, tree, _find_sim_load_host())


func _find_sim_load_host() -> Node:
	var sgv := get_tree().root.find_child("SystemGraphView", true, false) if get_tree() != null else null
	if sgv == null:
		return null
	return sgv.get_node_or_null("GraphSimLoadHost")


func _load_item_is_active(it: Dictionary) -> bool:
	if _is_load_group_item(it):
		if _ac_shed_active:
			return false
		return _load_group_draw_w(it) > WIRE_DEAD_W
	var ty: String = str(it.get("type", ""))
	if _ac_shed_active:
		if ty in ["appliance", "acload", "processor", "acoutlet", "acbreaker"]:
			return false
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	var st: String     = str(sp.get("current_state", "")).to_lower()
	var is_on_v: Variant = it.get("is_on", null)
	# explicit is_on flag (Govee-style)
	if is_on_v != null:
		if not bool(is_on_v):
			return false
	# current_state=="off" → definitely dead
	if st == "off":
		return false
	# current_state=="on" is the happy path
	if st == "on":
		var w: float = float(sp.get("avg_watts", sp.get("watts", sp.get("max_watts", 0.0))))
		return w > WIRE_DEAD_W
	# no state field: treat as active only if avg_watts > threshold
	var w: float = float(sp.get("avg_watts", sp.get("watts", sp.get("max_watts", 0.0))))
	return w > WIRE_DEAD_W


func _sum_all_load_w() -> float:
	if model == null:
		return 0.0
	var tree := get_tree()
	if tree == null:
		return 0.0
	return GraphAcLoad.compute_watts(model, tree)


func _is_ac_sink_type(item_type: String) -> bool:
	return item_type in ["appliance", "acload", "processor", "acoutlet", "acbreaker"]


func _refresh_ac_shed_state() -> void:
	var apb := _cached_autoload("/root/AcPowerBus")
	if apb != null and "ac_output_enabled" in apb:
		_ac_shed_active = not bool(apb.ac_output_enabled)
	else:
		_ac_shed_active = false


func _connection_is_ac_power(
		conn: Dictionary,
		sitem: Dictionary,
		titem: Dictionary,
		pol: String) -> bool:
	var rt: String = str(conn.get("resource_type", ""))
	if rt == "power" or rt == "ac":
		return true
	if pol == "ac" or pol == "load":
		return true
	var st: String = str(sitem.get("type", ""))
	var tt: String = str(titem.get("type", ""))
	if st == "controller" and _is_ac_sink_type(tt):
		return true
	if tt == "controller" and _is_ac_sink_type(st):
		return true
	if _is_ac_sink_type(st) or _is_ac_sink_type(tt):
		return pol != "positive" and pol != "negative" and pol != "pvPositive" and pol != "pvNegative"
	return false


## Combined live output (W) of all wind/hydro generator items on the canvas.
func _renewable_output_w() -> float:
	if model == null:
		return 0.0
	var total := 0.0
	for it: Dictionary in _visible_items():
		var ty: String = it.get("type", "") as String
		if ty != "wind" and ty != "hydro":
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		total += maxf(0.0, float(sp.get("current_output_kw", 0.0)) * 1000.0)
	return total


## Live PV output in watts — sum every panel / virtual array node.
func _solar_array_output_w() -> float:
	if model == null:
		return 0.0
	var total := 0.0
	var found := false
	for it: Dictionary in _visible_items():
		var iid: String = it.get("id", "") as String
		if iid == "virtual_solar_array" or it.get("type", "") == "panel":
			var sp: Dictionary = it.get("specs", {}) as Dictionary
			total += maxf(0.0, float(sp.get("current_output_kw", 0.0)) * 1000.0)
			found = true
	return total if found else 0.0


## Estimated power (W), flow direction, and whether the wire is actively carrying power.
## Returns {watts: float, reverse: bool, active: bool, shed: bool}.
func _estimate_connection_flow(
		conn: Dictionary, solar_w: float, load_w: float) -> Dictionary:
	if model == null:
		return {"watts": 80.0, "reverse": false, "active": false, "shed": false}
	var sid: String = conn.get("source_item_id", "") as String
	var tid: String = conn.get("target_item_id", "") as String
	var pol: String = conn.get("polarity", "") as String
	var sitem: Dictionary = model.get_item(sid)
	var titem: Dictionary = model.get_item(tid)
	if sitem.is_empty() or titem.is_empty():
		return {"watts": WIRE_FLOW_FLOOR, "reverse": false, "active": false, "shed": false}
	if _ac_shed_active and _connection_is_ac_power(conn, sitem, titem, pol):
		return {"watts": WIRE_FLOW_FLOOR, "reverse": false, "active": false, "shed": true}
	var st: String = sitem.get("type", "") as String
	var tt: String = titem.get("type", "") as String
	var net: float  = solar_w - load_w

	# Shelly Pro 4PM upstream wire: show sum of all metered circuit loads
	if tt == "shelly4pm" and pol == "ac":
		var tsp: Dictionary = titem.get("specs", {}) as Dictionary
		var shelly_total := 0.0
		for ci: int in 4:
			shelly_total += float(tsp.get("c%d_power_w" % ci, 0.0))
		shelly_total = maxf(WIRE_FLOW_FLOOR, shelly_total)
		return {"watts": shelly_total, "reverse": false, "active": shelly_total > WIRE_DEAD_W}

	# Inverter / AC bus → loads: animate only when that specific load is ON
	if pol == "ac" or pol == "load" or (st == "controller" and _is_ac_sink_type(tt)):
		var load_item: Dictionary = {}
		if _is_ac_sink_type(tt) or _is_load_group_item(titem):
			load_item = titem
		elif _is_ac_sink_type(st) or _is_load_group_item(sitem):
			load_item = sitem
		if not _load_item_is_active(load_item):
			return {"watts": WIRE_FLOW_FLOOR, "reverse": false, "active": false}
		var w: float
		var batch_w := float(load_item.get("batch_active_watts", 0.0))
		if batch_w > 0.0:
			# Real per-phase draw computed by ResourceFlowEngine batch sim.
			w = maxf(WIRE_FLOW_FLOOR, batch_w)
		elif _is_load_group_item(load_item):
			w = maxf(WIRE_FLOW_FLOOR, _load_group_draw_w(load_item))
		else:
			var tsp: Dictionary = load_item.get("specs", {}) as Dictionary
			w = maxf(WIRE_FLOW_FLOOR, float(
				tsp.get("avg_watts", tsp.get("watts", tsp.get("max_watts", 200.0)))))
		var reverse_ac: bool = (tt == "controller")
		return {"watts": w, "reverse": reverse_ac, "active": true}

	# Wind/hydro generator wires: animate from that generator's own output
	if st == "wind" or st == "hydro" or tt == "wind" or tt == "hydro":
		var gen_item: Dictionary = sitem if (st == "wind" or st == "hydro") else titem
		var gsp: Dictionary = gen_item.get("specs", {}) as Dictionary
		var gw: float = maxf(0.0, float(gsp.get("current_output_kw", 0.0)) * 1000.0)
		return {"watts": maxf(gw, 5.0), "reverse": false, "active": gw > WIRE_DEAD_W}

	# DC-electricity generator wires (fuel processors with a dc_electricity
	# output, e.g. the Woodgas DC Generator): animate from its live
	# fuel-throughput-derived current_output_kw telemetry.
	if (st == "processor" and pol in ["positive", "negative"]) \
			or (tt == "processor" and pol in ["positive", "negative"]):
		var gen_item2: Dictionary = sitem if st == "processor" else titem
		var gsp2: Dictionary = gen_item2.get("specs", {}) as Dictionary
		var has_dc_out := false
		for dc_o: Variant in (gsp2.get("outputs", []) as Array):
			if dc_o is Dictionary and str((dc_o as Dictionary).get("kind", "")) == "dc_electricity":
				has_dc_out = true
				break
		if has_dc_out:
			var gw2: float = maxf(0.0, float(gsp2.get("current_output_kw", 0.0)) * 1000.0)
			return {"watts": maxf(gw2, 5.0), "reverse": false, "active": gw2 > WIRE_DEAD_W}

	# PV string → controller: only animate when panels are actually producing
	if sid == "virtual_solar_array" or tid == "virtual_solar_array" or st == "panel" or tt == "panel":
		var producing: bool = solar_w > WIRE_DEAD_W
		var w_pv: float = maxf(solar_w, 5.0)
		if w_pv < 20.0:
			w_pv = 5.0 + solar_w * 0.15
		return {"watts": w_pv, "reverse": false, "active": producing}

	# Controller ↔ battery (virtual or real StarShade / LinkageLab nodes)
	var bat_ctrl := (_is_battery_type(st) and tt == "controller") \
			or (st == "controller" and _is_battery_type(tt)) \
			or (sid == "virtual_controller" and tid == "virtual_battery") \
			or (sid == "virtual_battery" and tid == "virtual_controller")
	if bat_ctrl:
		# Prefer the real battery flow published by SolarUI (via SystemGraphView)
		# over the |net|*0.95 heuristic.
		var bat_w := net
		if bool(live_power_hint.get("valid", false)):
			bat_w = float(live_power_hint.get("battery_w", net))
		var w_b: float  = minf(12000.0, maxf(WIRE_FLOW_FLOOR, absf(bat_w)))
		var rev:  bool  = (bat_w < 0.0) # discharge: power runs battery → controller
		var active_b: bool = (w_b > WIRE_DEAD_W * 2.0) or solar_w > WIRE_DEAD_W
		return {"watts": w_b, "reverse": rev, "active": active_b}

	# Resource flow wires — Sankey width from ResourceFlowEngine throughput
	if pol == "resource":
		var kind: String = str(conn.get("resource_type", ""))
		if kind.is_empty():
			kind = _resource_kind_for_port(sid, conn.get("source_handle_id", "") as String)
		kind = ResourceKinds.normalize_kind(kind)
		var flow_rate: float = 0.0
		var active_r: bool = false
		if resource_flow_engine != null and resource_flow_engine.has_method("get_connection_flow"):
			var rf: Dictionary = resource_flow_engine.call(
				"get_connection_flow", str(conn.get("id", ""))) as Dictionary
			flow_rate = float(rf.get("rate", 0.0))
			active_r = bool(rf.get("active", false))
			if kind.is_empty() and rf.has("kind"):
				kind = ResourceKinds.normalize_kind(str(rf.get("kind", "")))
		if flow_rate <= ResourceEdgeVis.FLOW_DEAD_RATE and conn.get("flow_rate") != null:
			flow_rate = float(conn.get("flow_rate", 0.0))
		if not active_r and bool(conn.get("flow_active", false)):
			active_r = true
		return {
			"watts": flow_rate,
			"rate": flow_rate,
			"reverse": false,
			"active": active_r,
			"is_resource": true,
			"resource_kind": kind,
		}

	# Other DC: carry same net magnitude as a hint, consider active if net > threshold
	var w2: float = minf(8000.0, maxf(40.0, 0.5 * (solar_w + load_w) + 50.0))
	return {"watts": w2, "reverse": false, "active": (solar_w + load_w) > WIRE_DEAD_W * 4.0}


func _processor_is_active(item: Dictionary) -> bool:
	return _load_item_is_active(item)


func _wire_glow_scale_from_watts(watts: float) -> float:
	var t: float  = clampf(watts / WIRE_GLOW_W_REF, 0.0, 1.2)
	# Slight log curve for wide dynamic range
	var s: float  = pow(t, 0.65) as float
	return lerpf(WIRE_GLOW_MIN, WIRE_GLOW_MAX, s)


func _draw_connections() -> void:
	if model == null:
		return
	var center  := size * 0.5
	# Generation feeding the DC bus: solar array plus wind/hydro items.
	var solar_w: float  = _solar_array_output_w() + _renewable_output_w()
	var load_w: float   = _sum_all_load_w()
	var visible := _visible_connections()
	_wire_lod_simplify = visible.size() > WIRE_LOD_HIGH_COUNT or _zoom < WIRE_LOD_ZOOM_CUTOFF
	for conn: Dictionary in visible:
		_render_connection(conn, center, solar_w, load_w)


## Segment count for a bezier stroke of `base` reference segments (tuned for
## a ~260px on-screen wire), scaled down for shorter/zoomed-out wires so the
## fixed 24-34 segment counts don't spend draw_line calls a short span can't
## show anyway. `_draw_bezier_stroke` already skips sub-pixel segments, but
## computing fewer of them in the first place avoids the interpolation work.
func _adaptive_segments(pixel_len: float, base: int, floor_segs: int = 8) -> int:
	if base <= floor_segs:
		return base
	var frac := clampf(pixel_len / WIRE_SEG_REF_LEN, 0.0, 1.0)
	return maxi(floor_segs, int(round(lerpf(float(floor_segs), float(base), frac))))


func _render_connection(
		conn: Dictionary, center: Vector2, solar_w: float, load_w: float) -> void:
	var sid: String = conn.get("source_item_id", "") as String
	var tid: String = conn.get("target_item_id", "") as String
	var pol: String = conn.get("polarity", "positive") as String
	var src := _get_handle_info(
		sid, conn.get("source_handle_id", "") as String, center, tid, pol)
	var tgt := _get_handle_info(
		tid, conn.get("target_handle_id", "") as String, center, sid, pol)
	if src.is_empty() or tgt.is_empty():
		return

	var polarity    := conn.get("polarity", "positive") as String
	var is_sel:  bool = (conn.get("id", "") as String == selected_connection_id)
	var is_resource_wire: bool = polarity == "resource"
	var flow_est      := _estimate_connection_flow(conn, solar_w, load_w)
	var flow_watts:   float  = float(flow_est.get("watts", 100.0))
	var reverse: bool = bool(flow_est.get("reverse", false))
	var flow_active:  bool   = bool(flow_est.get("active", true))
	var wire_shed: bool = bool(flow_est.get("shed", false))

	var base_col  := _wire_color_for_connection(conn, polarity)
	if is_resource_wire:
		var rk: String = str(flow_est.get("resource_kind", conn.get("resource_type", "")))
		base_col = ResourceKinds.wire_color(ResourceKinds.normalize_kind(rk))
	if bool(conn.get("voltage_mismatch", false)):
		base_col = Color(1.0, 0.15, 0.15, 0.95)
	if bool(conn.get("needs_pump", false)):
		base_col = Color(1.0, 0.55, 0.12, 0.95)
	if bool(conn.get("severed", false)):
		# Wave 8 burnout: scorched charcoal wire, no flow animation.
		base_col = Color(0.16, 0.13, 0.11, 0.9)
		flow_active = false
	var col: Color = C_SELECTED_BORDER if is_sel else base_col
	if wire_shed:
		flow_active = false
		var flash: float = 0.62 + 0.38 * abs(sin(_flow_phase * 7.5))
		col = Color(col.r * 0.40 * flash, col.g * 0.40 * flash, col.b * 0.40 * flash, 0.45 + 0.25 * flash)

	var width: float
	var res_rate: float = 0.0
	var res_kind: String = ""
	if is_resource_wire:
		var rk2: String = ResourceKinds.normalize_kind(
			str(flow_est.get("resource_kind", conn.get("resource_type", ""))))
		res_kind = rk2
		res_rate = float(flow_est.get("rate", flow_watts))
		var stroke: Dictionary = ResourceEdgeVis.stroke_for(
			rk2, res_rate, flow_active, is_sel)
		col = stroke.get("color", col) as Color
		if bool(conn.get("type_mismatch", false)):
			col = UITheme.C_WARN.lerp(col, 0.35)
		# Wire body scales with zoom so ribbons stay proportional to the nodes.
		width = float(stroke.get("width", ResourceEdgeVis.WIDTH_IDLE)) * _zoom
	else:
		var gscale_w  := _wire_glow_scale_from_watts(flow_watts)
		width = (6.5 if is_sel else WIRE_BASE_W + gscale_w * 2.4) * _zoom

	# In Test mode wires animate if power is actually flowing; Build mode is always static
	var flowing: bool = (current_mode == "test") and flow_active

	var tgt_tang_in := _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)
	var wps: Array = _waypoints_screen(conn, center)
	var style: String = str(conn.get("line_style", "bezier"))
	var curve_t := _conn_curve_tension(conn)
	var src_pos: Vector2 = src.get("pos", Vector2.ZERO) as Vector2
	var tgt_pos: Vector2 = tgt.get("pos", Vector2.ZERO) as Vector2
	
	if bool(src.get("hub", false)):
		var next_pt: Vector2
		if wps.size() > 0:
			next_pt = wps[0]
		else:
			var t_item = model.get_item(tid)
			next_pt = _item_screen_tl(t_item, center) + _item_screen_size(t_item) * 0.5
			
		var s_item = model.get_item(sid)
		var s_center = _item_screen_tl(s_item, center) + _item_screen_size(s_item) * 0.5
		var ang = GraphHubPorts.angle_from_center_to_point(s_center, next_pt)
		src_pos = GraphHubPorts.screen_pos_on_circle(_item_screen_tl(s_item, center), _item_screen_size(s_item), ang)
		src["tangent"] = GraphHubPorts.outward_tangent(ang)
		src["pos"] = src_pos
		
	if bool(tgt.get("hub", false)):
		var prev_pt: Vector2
		if wps.size() > 0:
			prev_pt = wps[-1]
		else:
			var s_item = model.get_item(sid)
			prev_pt = _item_screen_tl(s_item, center) + _item_screen_size(s_item) * 0.5
			
		var t_item = model.get_item(tid)
		var t_center = _item_screen_tl(t_item, center) + _item_screen_size(t_item) * 0.5
		var ang = GraphHubPorts.angle_from_center_to_point(t_center, prev_pt)
		tgt_pos = GraphHubPorts.screen_pos_on_circle(_item_screen_tl(t_item, center), _item_screen_size(t_item), ang)
		tgt["tangent"] = GraphHubPorts.outward_tangent(ang)
		tgt["pos"] = tgt_pos

	var src_t: Vector2 = src.get("tangent", Vector2.RIGHT) as Vector2
	tgt_tang_in = _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)

	# Connection style overrides
	var c_color = str(conn.get("color_override", ""))
	if not c_color.is_empty():
		col = Color(c_color)
	var c_thick = float(conn.get("thickness_override", 0.0))
	if c_thick > 0.1:
		width = c_thick * _zoom
	var sankey_scale = bool(conn.get("sankey_scale", true))

	if is_resource_wire:
		# Radiant (sunlight) links are always dashed/glowing regardless of
		# line_style — they visualize an ambient, non-blocking connection
		# rather than a piped one (Phase 3 solar PBI).
		# Ambient radiant links (sunlight / wind) are always dashed/glowing
		# regardless of line_style — they visualize optional non-blocking
		# environment links (see atmosphere_pbi.gd / solar_pbi_selftest.gd).
		if res_kind == "sunlight" or res_kind == "wind":
			if wps.is_empty():
				_draw_radiant_wire_bezier(
					src_pos, src_t, tgt_pos, tgt_tang_in, col, width, flowing, curve_t, res_rate, res_kind)
			else:
				_draw_radiant_wire_path(
					[src_pos] + wps + [tgt_pos], [src_t, tgt_tang_in],
					col, width, flowing, curve_t, res_rate, res_kind)
			# Always show the flux label when there's meaningful flux (educational),
			# even in Build mode — radiant links are documentary.
			if res_rate > ResourceEdgeVis.FLOW_DEAD_RATE and _zoom >= WIRE_LABEL_MIN_ZOOM:
				_draw_flow_label(src_pos, tgt_pos, wps, res_rate, true, res_kind, col)
			_draw_connection_waypoint_handles(conn, center)
			return
		if style == "metro":
			var pts_r: Array = [src_pos] + wps + [tgt_pos]
			_draw_wire_metro_path(pts_r, [src_t, tgt_tang_in], col, width, flowing, res_rate, reverse, conn)
		elif style == "orthogonal":
			var pts_r: Array = [src_pos] + wps + [tgt_pos]
			_draw_resource_wire_orthogonal_path(
				pts_r, [src_t, tgt_tang_in], col, width, flowing, reverse, curve_t,
				res_rate, res_kind, sankey_scale)
		elif wps.is_empty():
			_draw_resource_wire_bezier(
				src_pos, src_t, tgt_pos, tgt_tang_in, col, width, flowing, reverse, curve_t,
				res_rate, res_kind, sankey_scale)
		else:
			_draw_resource_wire_path(
				[src_pos] + wps + [tgt_pos], [src_t, tgt_tang_in],
				col, width, flowing, reverse, curve_t, res_rate, res_kind, sankey_scale)
		if flowing and _zoom >= WIRE_LABEL_MIN_ZOOM:
			_draw_flow_label(src_pos, tgt_pos, wps, res_rate, true, res_kind, col)
		_draw_connection_waypoint_handles(conn, center)
		return
	if style == "metro":
		var pts: Array = [src_pos] + wps + [tgt_pos]
		_draw_wire_metro_path(pts, [src_t, tgt_tang_in], col, width, flowing, flow_watts, reverse, conn)
	elif style == "orthogonal":
		var pts: Array = [src_pos] + wps + [tgt_pos]
		_draw_wire_orthogonal_path(
			pts, [src_t, tgt_tang_in], col, width, flowing, flow_watts, reverse, conn)
	elif wps.is_empty():
		_draw_wire_bezier(src_pos, src_t, tgt_pos, tgt_tang_in,
			col, width, flowing, flow_watts, reverse, curve_t)
	else:
		_draw_wire_path(
			[src_pos] + wps + [tgt_pos],
			[src_t, tgt_tang_in],
			col, width, flowing, flow_watts, reverse, curve_t)
	if flowing and _zoom >= WIRE_LABEL_MIN_ZOOM:
		_draw_flow_label(src_pos, tgt_pos, wps, flow_watts, false, "", col)
	_draw_connection_waypoint_handles(conn, center)


# Flow-rate labels on wires (Test mode only — callers gate on `flowing`).
const WIRE_LABEL_MIN_ZOOM := 0.8
const WIRE_LABEL_FONT_PX := 10.0   # graph-space design size (× _zoom on draw)

## Small readout pill at the wire midpoint: "512 W" / "1.20 kW" for electrical,
## "6.3 L/h" for typed resources.
func _draw_flow_label(src_pos: Vector2, tgt_pos: Vector2, wps: Array,
		value: float, is_resource: bool, kind: String, wire_col: Color) -> void:
	var txt: String
	if is_resource:
		if value <= ResourceEdgeVis.FLOW_DEAD_RATE:
			return
		if kind == "sunlight" or kind == "wind":
			# Instantaneous SoI flux (kW), not a per-hour accumulation like
			# rain — omit the "/h" so the readout stays dimensionally honest.
			txt = ("%.2f MW" % (value / 1000.0)) if value >= 1000.0 else ("%.1f kW" % value)
		else:
			txt = "%.1f %s/h" % [value, ResourceKinds.default_unit(kind)]
	else:
		if value < WIRE_DEAD_W:
			return
		txt = ("%.2f kW" % (value / 1000.0)) if value >= 1000.0 else ("%d W" % int(round(value)))

	# Midpoint of the middle segment of the (src + waypoints + tgt) polyline —
	# robust for bezier and orthogonal styles without resampling the curve.
	var pts: Array = [src_pos] + wps + [tgt_pos]
	@warning_ignore("integer_division")
	var mid_seg: int = (pts.size() - 1) / 2
	var mid: Vector2 = ((pts[mid_seg] as Vector2) + (pts[mini(mid_seg + 1, pts.size() - 1)] as Vector2)) * 0.5

	var fnt := ThemeDB.fallback_font
	var fs := maxi(6, int(round(WIRE_LABEL_FONT_PX * _zoom)))
	var ts := fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad := 3.0 * _zoom
	var rect := Rect2(mid - ts * 0.5 - Vector2(pad, pad),
			ts + Vector2(pad * 2.0, pad * 2.0))
	draw_rect(rect, Color(0.04, 0.06, 0.11, 0.85), true)
	draw_rect(rect, Color(wire_col.r, wire_col.g, wire_col.b, 0.45), false, maxf(0.8, 1.0 * _zoom))
	var txt_col := Color(
		lerpf(wire_col.r, 1.0, 0.35),
		lerpf(wire_col.g, 1.0, 0.35),
		lerpf(wire_col.b, 1.0, 0.35), 0.96)
	draw_string(fnt, Vector2(rect.position.x + pad, rect.end.y - pad - fs * 0.18),
		txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, txt_col)


func _bezier_pos(from: Vector2, c1: Vector2, c2: Vector2, to: Vector2, t: float) -> Vector2:
	return from.bezier_interpolate(c1, c2, to, t)


## Sankey-style typed resource wire — width/color from ResourceEdgeVis; glow + flow cues.
func _draw_resource_wire_bezier(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2,
		col: Color, width: float, flow_active: bool,
		reverse_chase: bool, curve_tension: float = 1.0,
		flow_rate: float = 0.0, resource_kind: String = "", sankey_scale: bool = true) -> void:
	var ctrl := _wire_bezier_controls(from, from_tang, to, to_tang_in, curve_tension)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]
	var gscale := ResourceEdgeVis.glow_scale(resource_kind, flow_rate, flow_active)
	var body_w := width if not sankey_scale else ResourceEdgeVis.body_width(width, gscale)
	var pixel_len := from.distance_to(to)
	# Ghost track (route visible when idle)
	_draw_bezier_stroke(from, c1, c2, to, _adaptive_segments(pixel_len, 24),
		Color(col.r, col.g, col.b, col.a * 0.20), maxf(1.4, width * 0.65))
	if flow_active and gscale > 0.01 and not _wire_lod_simplify:
		var glow_a := 0.07 + 0.13 * gscale
		_draw_bezier_stroke(from, c1, c2, to, _adaptive_segments(pixel_len, 28),
			Color(col.r, col.g, col.b, glow_a), body_w + 2.2 + 2.4 * gscale)
	var core := Color(
		lerpf(col.r, 1.0, 0.14 * gscale),
		lerpf(col.g, 1.0, 0.12 * gscale),
		lerpf(col.b, 1.0, 0.08 * gscale),
		lerpf(col.a, 1.0, 0.12 * gscale))
	_draw_bezier_stroke(from, c1, c2, to, _adaptive_segments(pixel_len, 30), core, maxf(1.6, body_w))
	if flow_active:
		ResourceEdgeVis.draw_bezier_flow_cues(
			self, from, c1, c2, to, col, body_w, _flow_phase, reverse_chase)


## Radiant (sunlight / wind) wire — always rendered dashed + soft-glowing, never
## solid, to signal it's an OPTIONAL/AMBIENT link. Dash speed and glow scale with
## SoI flux (`flow_rate` in kW).
func _draw_radiant_wire_bezier(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2, col: Color, width: float,
		flow_active: bool, curve_tension: float = 1.0, flow_rate: float = 0.0,
		res_kind: String = "sunlight") -> void:
	var ctrl := _wire_bezier_controls(from, from_tang, to, to_tang_in, curve_tension)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]
	var pixel_len := from.distance_to(to)
	var segs := _adaptive_segments(pixel_len, 30)
	var gscale := ResourceEdgeVis.glow_scale(
			res_kind, flow_rate, flow_active or flow_rate > ResourceEdgeVis.FLOW_DEAD_RATE)
	var dash_len: float = maxf(6.0 * _zoom, 2.0)
	var gap_len: float = maxf(5.0 * _zoom, 2.0)
	# Marching speed scales with flux intensity (idle = static dashes).
	var speed: float = 10.0 + 50.0 * gscale
	var offset: float = -_flow_phase * speed if (flow_active or gscale > 0.01) else 0.0
	var body_w: float = maxf(1.2, width * (0.85 + 0.55 * gscale))
	# Soft under-glow proportional to flux.
	if gscale > 0.01 and not _wire_lod_simplify:
		_draw_bezier_stroke_dashed(from, c1, c2, to, segs,
			Color(col.r, col.g, col.b, 0.10 + 0.18 * gscale),
			body_w + (4.0 + 8.0 * gscale) * _zoom, dash_len, gap_len, offset)
	var alpha: float = lerpf(0.38, 0.95, gscale) if gscale > 0.01 else 0.38
	_draw_bezier_stroke_dashed(from, c1, c2, to, segs,
		Color(col.r, col.g, col.b, alpha), body_w, dash_len, gap_len, offset)


## Multi-segment version of `_draw_radiant_wire_bezier` for waypointed links.
func _draw_radiant_wire_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool, curve_tension: float = 1.0,
		flow_rate: float = 0.0, res_kind: String = "sunlight") -> void:
	if points.size() < 2:
		return
	for seg: int in range(points.size() - 1):
		var from: Vector2 = points[seg] as Vector2
		var to: Vector2 = points[seg + 1] as Vector2
		var from_t: Vector2
		var to_t_in: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_in = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_in = (from - to).normalized()
		_draw_radiant_wire_bezier(from, from_t, to, to_t_in, col, width, flow_active, curve_tension, flow_rate, res_kind)


func _draw_resource_wire_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool,
		reverse_chase: bool, curve_tension: float = 1.0,
		flow_rate: float = 0.0, resource_kind: String = "", sankey_scale: bool = true) -> void:
	if points.size() < 2:
		return
	var gscale := ResourceEdgeVis.glow_scale(resource_kind, flow_rate, flow_active)
	var body_w := width if not sankey_scale else ResourceEdgeVis.body_width(width, gscale)
	for seg: int in range(points.size() - 1):
		var from: Vector2 = points[seg] as Vector2
		var to: Vector2 = points[seg + 1] as Vector2
		var from_t: Vector2
		var to_t_in: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_in = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_in = (from - to).normalized()
		_draw_resource_wire_bezier(from, from_t, to, to_t_in, col, width, false,
				reverse_chase, curve_tension, flow_rate, resource_kind)
	if flow_active:
		var sample_fn := func(t: float) -> Vector2:
			return _sample_wire_path(points, end_tangents, t, curve_tension)
		var cue_w := ResourceEdgeVis.body_width(width, gscale)
		ResourceEdgeVis.draw_path_flow_cues(self, sample_fn, col, cue_w, _flow_phase, reverse_chase)


func _draw_resource_wire_orthogonal_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool,
		reverse_chase: bool, curve_tension: float = 1.0,
		flow_rate: float = 0.0, resource_kind: String = "", sankey_scale: bool = true) -> void:
	if points.size() < 2:
		return
	var gscale := ResourceEdgeVis.glow_scale(resource_kind, flow_rate, flow_active)
	var body_w := width if not sankey_scale else ResourceEdgeVis.body_width(width, gscale)
	for i in range(points.size() - 1):
		var a: Vector2 = points[i] as Vector2
		var b: Vector2 = points[i + 1] as Vector2
		draw_line(a, b, Color(col.r, col.g, col.b, col.a * 0.20), maxf(1.4, width * 0.65))
		if flow_active and gscale > 0.01:
			var glow_a := 0.07 + 0.13 * gscale
			draw_line(a, b, Color(col.r, col.g, col.b, glow_a), body_w + 1.8 + 2.0 * gscale)
		draw_line(a, b, col, maxf(1.6, body_w))
	if flow_active and points.size() >= 2:
		var total := 0.0
		var segs: Array = []
		for i in range(points.size() - 1):
			var a: Vector2 = points[i] as Vector2
			var b: Vector2 = points[i + 1] as Vector2
			total += a.distance_to(b)
			segs.append({"a": a, "b": b, "len": total})
		if total < 1.0:
			return
		var sample_fn := func(t: float) -> Vector2:
			var dist := t * total
			var prev := points[0] as Vector2
			for seg: Dictionary in segs:
				if dist <= float(seg.get("len", 0.0)):
					var seg_a: Vector2 = seg.get("a", Vector2.ZERO)
					var seg_b: Vector2 = seg.get("b", Vector2.ZERO)
					var seg_start_len: float = float(seg.get("len", 0.0)) - seg_a.distance_to(seg_b)
					var seg_len: float = maxf(seg_a.distance_to(seg_b), 0.001)
					var u: float = (dist - seg_start_len) / seg_len
					return seg_a.lerp(seg_b, clampf(u, 0.0, 1.0))
				prev = seg.get("b", prev) as Vector2
			return points[points.size() - 1] as Vector2
		ResourceEdgeVis.draw_path_flow_cues(self, sample_fn, col,
				ResourceEdgeVis.body_width(width, gscale), _flow_phase, reverse_chase)


## Glow underlay + main stroke + moving chase (source → target; `reverse` when battery discharges).
func _draw_wire_bezier(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2,
		col: Color, width: float, flow_active: bool,
		flow_watts: float, reverse_chase: bool, curve_tension: float = 1.0) -> void:
	var ctrl := _wire_bezier_controls(from, from_tang, to, to_tang_in, curve_tension)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]
	var gscale: float  = _wire_glow_scale_from_watts(flow_watts)
	var extra: float  = 4.0 + 18.0 * gscale
	# Body is fully opaque when power is high, but stays visible when idle
	var body_alpha: float  = 0.60 + 0.40 * gscale
	var pixel_len := from.distance_to(to)

	# 1) Glow halo — concentric passes, innermost brightest. Full lushness (3
	# passes + a bright inner halo) when few wires are on screen; a single
	# pass and no inner halo once WIRE_LOD_HIGH_COUNT wires are visible or the
	# view is zoomed out far enough that the extra passes aren't perceptible.
	if flow_active and flow_watts > WIRE_FLOW_FLOOR * 0.5:
		var glow_passes := 1 if _wire_lod_simplify else 3
		var glow_segs := _adaptive_segments(pixel_len, 28)
		for p in glow_passes:
			var layer: float = float(p) / float(maxi(glow_passes - 1, 1))
			# Outer passes are wider but more transparent; inner close to the wire body
			var gw: float = width + 1.5 + (extra) * (1.0 - layer * 0.55)
			var a_g:  float  = (0.15 - layer * 0.025) * gscale
			_draw_bezier_stroke(from, c1, c2, to, glow_segs, Color(col.r, col.g, col.b, a_g), gw)
		if not _wire_lod_simplify:
			# Extra tight inner halo at near-white to create a bright core
			var inner_w: float = width * 0.9
			var inner_a: float = 0.22 * gscale
			_draw_bezier_stroke(from, c1, c2, to, _adaptive_segments(pixel_len, 34),
				Color(lerpf(col.r, 1.0, 0.5), lerpf(col.g, 1.0, 0.5), lerpf(col.b, 1.0, 0.5), inner_a),
				inner_w)

	# 2) Main body — slightly whitened core at high power
	var core := Color(
		lerpf(col.r, 1.0, 0.18 * gscale),
		lerpf(col.g, 1.0, 0.15 * gscale),
		lerpf(col.b, 1.0, 0.12 * gscale),
		body_alpha)
	_draw_bezier_stroke(from, c1, c2, to, _adaptive_segments(pixel_len, 34), core, maxf(1.2, width))

	# 3) Chase: bright head + thin trail along the line
	# Chase count scales with power level and timescale so high-speed sim is still readable.
	# Simplified LOD keeps only the lead dot (flow direction/activity stays
	# legible) and drops the fading trail.
	if flow_active:
		var chase_count: int
		if _wire_lod_simplify:
			chase_count = 1
		else:
			var extra_dots := int(gscale * 3.0) + int(clampf(log(_sim_flow_mult + 1.0) * 1.2, 0.0, 4.0))
			chase_count = WIRE_CHASE_COUNT + extra_dots
		var spacing     := maxf(0.055, WIRE_CHASE_SPACING - gscale * 0.02)
		var t_base: float = fmod(_flow_phase * 0.34, 1.0)
		for s in chase_count:
			var t : float = t_base - float(s) * spacing
			if reverse_chase:
				t = 1.0 - t
			t = fposmod(t, 1.0)
			var t1: float   = t
			var t0: float   = maxf(0.0, t1 - 0.055 - 0.028 * gscale)
			var p0: Vector2 = _bezier_pos(from, c1, c2, to, t0)
			var p1: Vector2 = _bezier_pos(from, c1, c2, to, t1)
			# Fade tail dots so only the first few are fully bright
			var tail_fade := 1.0 - float(s) / float(chase_count)
			# Wide soft outer ring
			var wch_outer := maxf(3.5, width * (1.2 + 1.8 * gscale) + _zoom)
			draw_line(p0, p1, Color(col.r, col.g, col.b, (0.18 + 0.24 * gscale) * tail_fade), wch_outer)
			# Bright core
			var a_ch := (0.60 + 0.40 * gscale) * tail_fade
			var wch  := maxf(2.0, width * (0.9 + 1.5 * gscale) + 0.5 * _zoom)
			draw_line(p0, p1, Color(1, 0.99, 0.94, a_ch), wch)
			# White-hot tip (only on first dot)
			if s == 0:
				draw_line(p0, p1, Color(1, 1, 1, a_ch * 0.65), wch * 0.38)


## Multi-segment wire through optional waypoints (each segment is a cubic bezier).
func _draw_wire_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool,
		flow_watts: float, reverse_chase: bool, curve_tension: float = 1.0) -> void:
	if points.size() < 2:
		return
	for seg: int in range(points.size() - 1):
		var from: Vector2 = points[seg] as Vector2
		var to: Vector2 = points[seg + 1] as Vector2
		var from_t: Vector2
		var to_t_in: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_in = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_in = (from - to).normalized()
		_draw_wire_bezier(from, from_t, to, to_t_in, col, width, false, flow_watts, reverse_chase, curve_tension)
	if flow_active:
		_draw_bezier_path_chase(points, end_tangents, col, width, flow_watts, reverse_chase, curve_tension)


func _draw_bezier_path_chase(points: Array, end_tangents: Array,
		col: Color, width: float, flow_watts: float, reverse_chase: bool,
		curve_tension: float = 1.0) -> void:
	if points.size() < 2:
		return
	const SAMPLES := 48
	var total_len := 0.0
	var lengths: Array = [0.0]
	for i: int in range(1, SAMPLES + 1):
		var t0: float = float(i - 1) / float(SAMPLES)
		var t1: float = float(i) / float(SAMPLES)
		var p0: Vector2 = _sample_wire_path(points, end_tangents, t0, curve_tension)
		var p1: Vector2 = _sample_wire_path(points, end_tangents, t1, curve_tension)
		total_len += p0.distance_to(p1)
		lengths.append(total_len)
	if total_len < 1.0:
		return
	var gscale: float = _wire_glow_scale_from_watts(flow_watts)
	var chase_count: int
	if _wire_lod_simplify:
		chase_count = 1
	else:
		var extra_dots := int(gscale * 3.0) + int(clampf(log(_sim_flow_mult + 1.0) * 1.2, 0.0, 4.0))
		chase_count = WIRE_CHASE_COUNT + extra_dots
	var spacing := maxf(0.055, WIRE_CHASE_SPACING - gscale * 0.02)
	var t_base: float = fmod(_flow_phase * 0.34, 1.0)
	for s in chase_count:
		var t: float = t_base - float(s) * spacing
		if reverse_chase:
			t = 1.0 - t
		t = fposmod(t, 1.0)
		var dist_along := t * total_len
		var acc := 0.0
		var p0 := Vector2.ZERO
		var p1 := Vector2.ZERO
		var found := false
		for i: int in range(SAMPLES):
			var seg_len: float = float(lengths[i + 1]) - float(lengths[i])
			if acc + seg_len >= dist_along:
				var lt := (dist_along - acc) / maxf(seg_len, 0.001)
				var ta: float = float(i) / float(SAMPLES)
				var tb: float = float(i + 1) / float(SAMPLES)
				p0 = _sample_wire_path(points, end_tangents, lerpf(ta, tb, maxf(0.0, lt - 0.04)), curve_tension)
				p1 = _sample_wire_path(points, end_tangents, lerpf(ta, tb, lt), curve_tension)
				found = true
				break
			acc += seg_len
		if not found:
			continue
		var tail_fade := 1.0 - float(s) / float(chase_count)
		# `width` already carries zoom (see _render_connection).
		var wch_outer := maxf(3.5, width * (1.2 + 1.8 * gscale) + _zoom)
		draw_line(p0, p1, Color(col.r, col.g, col.b, (0.18 + 0.24 * gscale) * tail_fade), wch_outer)
		var a_ch := (0.60 + 0.40 * gscale) * tail_fade
		var wch := maxf(2.0, width * (0.9 + 1.5 * gscale) + 0.5 * _zoom)
		draw_line(p0, p1, Color(1, 0.99, 0.94, a_ch), wch)
		if s == 0:
			draw_line(p0, p1, Color(1, 1, 1, a_ch * 0.65), wch * 0.38)


func _orthogonal_leg(a: Vector2, b: Vector2, horiz_first: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.append(a)
	if a.distance_to(b) < 1.0:
		out.append(b)
		return out
	if absf(a.x - b.x) < 1.5 or absf(a.y - b.y) < 1.5:
		out.append(b)
		return out
	if horiz_first:
		out.append(Vector2(b.x, a.y))
	else:
		out.append(Vector2(a.x, b.y))
	out.append(b)
	return out


func _build_orthogonal_polyline(points: Array, end_tangents: Array) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var poly := PackedVector2Array()
	for seg: int in range(points.size() - 1):
		var a: Vector2 = points[seg] as Vector2
		var b: Vector2 = points[seg + 1] as Vector2
		var horiz := true
		if seg == 0 and end_tangents.size() > 0:
			var ft: Vector2 = end_tangents[0] as Vector2
			horiz = absf(ft.x) >= absf(ft.y)
		elif seg == points.size() - 2 and end_tangents.size() > 1:
			var tt: Vector2 = end_tangents[1] as Vector2
			horiz = absf(tt.x) >= absf(tt.y)
		var leg := _orthogonal_leg(a, b, horiz)
		for i: int in range(leg.size()):
			if poly.is_empty() or poly[poly.size() - 1].distance_to(leg[i]) > 0.5:
				poly.append(leg[i])
	return poly


func _round_polyline_corners(poly: PackedVector2Array, radius: float, arc_segments: int = 10) -> PackedVector2Array:
	if poly.size() < 3 or radius <= 1.0:
		return poly
	var out := PackedVector2Array()
	out.append(poly[0])
	for i: int in range(1, poly.size() - 1):
		var prev: Vector2 = poly[i - 1]
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[i + 1]
		var d1: Vector2 = (cur - prev).normalized()
		var d2: Vector2 = (nxt - cur).normalized()
		if absf(d1.dot(d2)) > 0.98:
			out.append(cur)
			continue
		var r: float = minf(radius, minf(prev.distance_to(cur) * 0.48, cur.distance_to(nxt) * 0.48))
		out.append(cur - d1 * r)
		for s: int in range(1, arc_segments + 1):
			var t: float = float(s) / float(arc_segments)
			var p1: Vector2 = cur - d1 * r
			var p2: Vector2 = cur + d2 * r
			# Quadratic ease for a smoother fillet than linear lerp.
			var ease_t := t * t * (3.0 - 2.0 * t)
			out.append(p1.lerp(p2, ease_t))
		out.append(cur + d2 * r)
	out.append(poly[poly.size() - 1])
	return out


func _draw_polyline_stroke(poly: PackedVector2Array, col: Color, line_w: float, segments_per_span: int = 1) -> void:
	if poly.size() < 2:
		return
	for i: int in range(poly.size() - 1):
		draw_line(poly[i], poly[i + 1], col, line_w)


func _draw_wire_orthogonal_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool,
		flow_watts: float, reverse_chase: bool, conn: Dictionary) -> void:
	var poly := _build_orthogonal_polyline(points, end_tangents)
	var radius_px := _conn_corner_radius_graph(conn) * _zoom
	poly = _round_polyline_corners(poly, maxf(6.0, radius_px))
	var gscale: float = _wire_glow_scale_from_watts(flow_watts)
	var body_alpha: float = 0.60 + 0.40 * gscale
	var core := Color(
		lerpf(col.r, 1.0, 0.18 * gscale),
		lerpf(col.g, 1.0, 0.15 * gscale),
		lerpf(col.b, 1.0, 0.12 * gscale),
		body_alpha)
	if flow_active and flow_watts > WIRE_FLOW_FLOOR * 0.5:
		_draw_polyline_stroke(poly, Color(col.r, col.g, col.b, 0.14 * gscale), width + 6.0 * gscale)
	_draw_polyline_stroke(poly, core, maxf(1.2, width))
	if flow_active and poly.size() >= 2:
		_draw_polyline_chase(poly, col, width, flow_watts, reverse_chase)


func _draw_polyline_chase(poly: PackedVector2Array, _col: Color, width: float,
		flow_watts: float, reverse_chase: bool) -> void:
	var total_len := 0.0
	for i: int in range(poly.size() - 1):
		total_len += poly[i].distance_to(poly[i + 1])
	if total_len < 1.0:
		return
	var gscale: float = _wire_glow_scale_from_watts(flow_watts)
	var chase_count: int
	if _wire_lod_simplify:
		chase_count = 1
	else:
		var extra_dots := int(gscale * 2.0) + int(clampf(log(_sim_flow_mult + 1.0), 0.0, 3.0))
		chase_count = WIRE_CHASE_COUNT + extra_dots
	var spacing := maxf(0.06, WIRE_CHASE_SPACING - gscale * 0.02)
	var t_base: float = fmod(_flow_phase * 0.34, 1.0)
	for s in chase_count:
		var t: float = t_base - float(s) * spacing
		if reverse_chase:
			t = 1.0 - t
		t = fposmod(t, 1.0)
		var dist_along := t * total_len
		var acc := 0.0
		var p0 := Vector2.ZERO
		var p1 := Vector2.ZERO
		for i: int in range(poly.size() - 1):
			var seg_len := poly[i].distance_to(poly[i + 1])
			if acc + seg_len >= dist_along:
				var lt := (dist_along - acc) / maxf(seg_len, 0.001)
				p1 = poly[i].lerp(poly[i + 1], lt)
				p0 = poly[i].lerp(poly[i + 1], maxf(0.0, lt - 0.05))
				break
			acc += seg_len
		var tail_fade := 1.0 - float(s) / float(chase_count)
		var wch := maxf(2.0, (width * (0.9 + 1.4 * gscale) + 0.5) * _zoom)
		draw_line(p0, p1, Color(1, 0.99, 0.94, (0.55 + 0.35 * gscale) * tail_fade), wch)
		if s == 0:
			draw_line(p0, p1, Color(1, 1, 1, 0.55 * tail_fade), wch * 0.42)


func _effective_waypoints_screen(conn: Dictionary, center: Vector2) -> Array:
	var wps := _waypoints_screen(conn, center)
	if not wps.is_empty():
		return wps
	var style := str(conn.get("line_style", ""))
	if style == "metro" or style == "orthogonal":
		var sid := str(conn.get("source_item_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		var pol := str(conn.get("polarity", "positive"))
		var src := _get_handle_info(sid, str(conn.get("source_handle_id", "")), center, tid, pol)
		var tgt := _get_get_handle_info_or_empty(tid, str(conn.get("target_handle_id", "")), center, sid, pol)
		if src.is_empty():
			src = _get_handle_info(sid, str(conn.get("source_handle_id", "")), center, tid, pol)
		if not src.is_empty() and not tgt.is_empty():
			var src_pos: Vector2 = src.get("pos", Vector2.ZERO)
			var tgt_pos: Vector2 = tgt.get("pos", Vector2.ZERO)
			var mid_y := (src_pos.y + tgt_pos.y) * 0.5
			var w1 := Vector2(src_pos.x, mid_y)
			var w2 := Vector2(tgt_pos.x, mid_y)
			return [w1, w2]
	return []


func _get_get_handle_info_or_empty(iid: String, hid: String, center: Vector2, skip_item: String, polarity: String) -> Dictionary:
	return _get_handle_info(iid, hid, center, skip_item, polarity)


func _draw_connection_waypoint_handles(conn: Dictionary, center: Vector2) -> void:
	if str(conn.get("id", "")) != selected_connection_id:
		return
	var wps := _effective_waypoints_screen(conn, center)
	var is_default := (_waypoints_screen(conn, center)).is_empty()
	for wp: Vector2 in wps:
		var r := maxf(5.0, 6.0 * _zoom)
		if is_default:
			# Draw default waypoints as white dot handles with subtle glow
			draw_circle(wp, r + 3.0, Color(1.0, 1.0, 1.0, 0.22))
			draw_circle(wp, r, Color.WHITE)
			draw_circle(wp, r * 0.45, Color(0.06, 0.09, 0.17, 0.9))
		else:
			draw_circle(wp, r + 3.0, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.22))
			draw_circle(wp, r, C_PRIMARY)
			draw_circle(wp, r * 0.45, Color(0.06, 0.09, 0.17, 0.9))


func _waypoint_hit(screen_pos: Vector2) -> Dictionary:
	if selected_connection_id.is_empty() or model == null:
		return {}
	var conn := model.get_connection(selected_connection_id)
	if conn.is_empty():
		return {}
	var center := size * 0.5
	var wps: Array = _effective_waypoints_screen(conn, center)
	var pick_r := maxf(10.0, 12.0 * _zoom)
	if _touch_input_active():
		pick_r = maxf(pick_r, TOUCH_SEGMENT_PICK_MIN)
	for i: int in range(wps.size()):
		if (wps[i] as Vector2).distance_to(screen_pos) < pick_r:
			return {"conn_id": selected_connection_id, "index": i}
	return {}


func _add_waypoint_on_connection(conn_id: String, screen_pos: Vector2) -> void:
	if model == null:
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty():
		return
	var wps: Array = _waypoints_graph(conn)
	wps.append(_screen_to_graph(screen_pos))
	_set_waypoints_graph(conn_id, wps)


func _remove_waypoint(conn_id: String, index: int) -> void:
	if model == null or index < 0:
		return
	var conn := model.get_connection(conn_id)
	if conn.is_empty():
		return
	var wps: Array = _waypoints_graph(conn)
	if index >= wps.size():
		return
	wps.remove_at(index)
	_set_waypoints_graph(conn_id, wps)


func _connection_polyline_graph(conn: Dictionary) -> PackedVector2Array:
	var center := size * 0.5
	var sid: String = conn.get("source_item_id", "") as String
	var tid: String = conn.get("target_item_id", "") as String
	var pol: String = conn.get("polarity", "positive") as String
	var src := _get_handle_info(
		sid, conn.get("source_handle_id", "") as String, center, tid, pol)
	var tgt := _get_handle_info(
		tid, conn.get("target_handle_id", "") as String, center, sid, pol)
	if src.is_empty() or tgt.is_empty():
		return PackedVector2Array()
	var wps: Array = _waypoints_graph(conn)
	var pts: Array = [_screen_to_graph(src.get("pos", Vector2.ZERO) as Vector2)]
	for wp: Variant in wps:
		pts.append(wp as Vector2)
	pts.append(_screen_to_graph(tgt.get("pos", Vector2.ZERO) as Vector2))
	var tgt_t_in := _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)
	return _build_orthogonal_polyline(
		pts, [src.get("tangent", Vector2.RIGHT) as Vector2, tgt_t_in])


func _connection_polyline_screen(conn: Dictionary, center: Vector2, apply_rounding: bool) -> PackedVector2Array:
	var sid: String = conn.get("source_item_id", "") as String
	var tid: String = conn.get("target_item_id", "") as String
	var pol: String = conn.get("polarity", "positive") as String
	var src := _get_handle_info(
		sid, conn.get("source_handle_id", "") as String, center, tid, pol)
	var tgt := _get_handle_info(
		tid, conn.get("target_handle_id", "") as String, center, sid, pol)
	if src.is_empty() or tgt.is_empty():
		return PackedVector2Array()
	var wps: Array = _waypoints_screen(conn, center)
	var pts: Array = [src.get("pos", Vector2.ZERO)] + wps + [tgt.get("pos", Vector2.ZERO)]
	var tgt_t_in := _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)
	var poly := _build_orthogonal_polyline(
		pts, [src.get("tangent", Vector2.RIGHT) as Vector2, tgt_t_in])
	if apply_rounding:
		poly = _round_polyline_corners(poly, maxf(6.0, _conn_corner_radius_graph(conn) * _zoom))
	return poly


func _connection_intersects_rect(conn: Dictionary, rect: Rect2, center: Vector2) -> bool:
	var sid: String = conn.get("source_item_id", "") as String
	var tid: String = conn.get("target_item_id", "") as String
	var pol: String = conn.get("polarity", "positive") as String
	var src := _get_handle_info(
		sid, conn.get("source_handle_id", "") as String, center, tid, pol)
	var tgt := _get_handle_info(
		tid, conn.get("target_handle_id", "") as String, center, sid, pol)
	if src.is_empty() or tgt.is_empty():
		return false
	
	var from: Vector2 = src["pos"]
	var to: Vector2 = tgt["pos"]
	if rect.has_point(from) or rect.has_point(to):
		return true
		
	var wps: Array = _waypoints_screen(conn, center)
	for wp in wps:
		if rect.has_point(wp as Vector2):
			return true
			
	var style: String = str(conn.get("line_style", "bezier"))
	if style == "orthogonal":
		var poly := _connection_polyline_screen(conn, center, true)
		for i in range(poly.size() - 1):
			if _rect_intersects_segment(rect, poly[i], poly[i+1]):
				return true
	elif style == "metro":
		var poly := _connection_polyline_screen(conn, center, false)
		for i in range(poly.size() - 1):
			if _rect_intersects_segment(rect, poly[i], poly[i+1]):
				return true
	else:
		# fallback rough check for bezier
		if _rect_intersects_segment(rect, from, to):
			return true
	
	return false

func _rect_intersects_segment(rect: Rect2, p1: Vector2, p2: Vector2) -> bool:
	if rect.has_point(p1) or rect.has_point(p2):
		return true
	var min_x = min(p1.x, p2.x)
	var max_x = max(p1.x, p2.x)
	var min_y = min(p1.y, p2.y)
	var max_y = max(p1.y, p2.y)
	if min_x > rect.end.x or max_x < rect.position.x or min_y > rect.end.y or max_y < rect.position.y:
		return false
	return true


func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.01:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _segment_is_horizontal(a: Vector2, b: Vector2) -> bool:
	return absf(a.y - b.y) <= absf(a.x - b.x)


func _ortho_segment_hit(screen_pos: Vector2) -> Dictionary:
	if selected_connection_id.is_empty() or model == null:
		return {}
	var conn := model.get_connection(selected_connection_id)
	if conn.is_empty():
		return {}
	var style := str(conn.get("line_style", "bezier"))
	if style != "orthogonal" and style != "metro":
		return {}
	var center := size * 0.5
	var poly := _connection_polyline_screen(conn, center, false)
	if poly.size() < 2:
		return {}
	var pick_dist := 10.0
	if _touch_input_active():
		pick_dist = maxf(pick_dist, TOUCH_SEGMENT_PICK_MIN)
	var best_idx := -1
	var best_dist := pick_dist
	for i: int in range(poly.size() - 1):
		var p0: Vector2 = poly[i]
		var p1: Vector2 = poly[i + 1]
		var d := _point_segment_distance(screen_pos, p0, p1)
		if d < best_dist:
			best_dist = d
			best_idx = i
	if best_idx < 0:
		return {}
	return {
		"conn_id": selected_connection_id,
		"seg_index": best_idx,
		"horizontal": _segment_is_horizontal(poly[best_idx], poly[best_idx + 1]),
	}


func _begin_ortho_segment_drag(hit: Dictionary, screen_pos: Vector2) -> void:
	var conn_id: String = str(hit.get("conn_id", ""))
	var conn := model.get_connection(conn_id) if model != null else {}
	if conn.is_empty():
		return
	_ortho_seg_dragging = true
	_ortho_seg_drag_conn = conn_id
	_ortho_seg_drag_idx = int(hit.get("seg_index", -1))
	_ortho_seg_drag_horiz = bool(hit.get("horizontal", true))
	_ortho_drag_poly_start = _connection_polyline_graph(conn)
	_ortho_drag_start_graph = _screen_to_graph(screen_pos)
	_touch_interaction = "ortho_seg"


func _apply_ortho_segment_drag(screen_pos: Vector2) -> void:
	if model == null or _ortho_seg_drag_idx < 0 or _ortho_drag_poly_start.size() < 2:
		return
	var conn := model.get_connection(_ortho_seg_drag_conn)
	if conn.is_empty():
		return
	var graph_pos := _screen_to_graph(screen_pos)
	var delta := graph_pos - _ortho_drag_start_graph
	var poly := _ortho_drag_poly_start.duplicate()
	var i := _ortho_seg_drag_idx
	if i >= poly.size() - 1:
		return
	if _ortho_seg_drag_horiz:
		var dy := delta.y
		poly[i].y = _ortho_drag_poly_start[i].y + dy
		poly[i + 1].y = _ortho_drag_poly_start[i + 1].y + dy
	else:
		var dx := delta.x
		poly[i].x = _ortho_drag_poly_start[i].x + dx
		poly[i + 1].x = _ortho_drag_poly_start[i + 1].x + dx
	_set_waypoints_graph(_ortho_seg_drag_conn, _extract_waypoints_from_poly(poly))


func _extract_waypoints_from_poly(poly: PackedVector2Array) -> Array:
	if poly.size() < 3:
		return []
	var wps: Array = []
	for i: int in range(1, poly.size() - 1):
		var prev: Vector2 = poly[i - 1]
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[i + 1]
		var d1: Vector2 = (cur - prev).normalized()
		var d2: Vector2 = (nxt - cur).normalized()
		if absf(d1.dot(d2)) < 0.98:
			wps.append(cur)
	return wps


func _sample_wire_path(points: Array, end_tangents: Array, t_global: float,
		curve_tension: float = 1.0) -> Vector2:
	if points.size() < 2:
		return points[0] as Vector2 if points.size() > 0 else Vector2.ZERO
	var segs := points.size() - 1
	var t_seg := t_global * float(segs)
	var seg := int(floor(t_seg))
	seg = clampi(seg, 0, segs - 1)
	var local_t := t_seg - float(seg)
	var from: Vector2 = points[seg] as Vector2
	var to: Vector2 = points[seg + 1] as Vector2
	var from_t: Vector2
	var to_t_in: Vector2
	if seg == 0:
		from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
	else:
		from_t = (to - from).normalized()
	if seg == segs - 1:
		to_t_in = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
	else:
		to_t_in = (from - to).normalized()
	var ctrl := _wire_bezier_controls(from, from_t, to, to_t_in, curve_tension)
	return from.bezier_interpolate(ctrl["c1"], ctrl["c2"], to, local_t)


## Solid polyline along cubic bezier
func _draw_bezier_stroke(
		from: Vector2, c1: Vector2, c2: Vector2, to: Vector2, segments: int, col: Color, line_w: float) -> void:
	var prev: Vector2  = from
	for i in range(1, segments + 1):
		var t:   float  = float(i) / float(segments)
		var p:  Vector2 = from.bezier_interpolate(c1, c2, to, t)
		if prev.distance_squared_to(p) < 0.1:
			continue
		draw_line(prev, p, col, line_w)
		prev = p


## Dashed variant of `_draw_bezier_stroke` — walks cumulative screen-space
## distance along the curve so dash/gap length stay constant regardless of
## curve length or segment count. `offset` (px) shifts the pattern; feed a
## time-varying offset for a "marching" animation (used by radiant wires).
func _draw_bezier_stroke_dashed(from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		segments: int, col: Color, line_w: float,
		dash_len: float, gap_len: float, offset: float = 0.0) -> void:
	var period := maxf(dash_len + gap_len, 0.001)
	var prev: Vector2 = from
	var dist_walked := offset
	for i in range(1, segments + 1):
		var t: float = float(i) / float(segments)
		var p: Vector2 = from.bezier_interpolate(c1, c2, to, t)
		var seg_len := prev.distance_to(p)
		if seg_len < 0.05:
			continue
		if fposmod(dist_walked, period) < dash_len:
			draw_line(prev, p, col, line_w)
		dist_walked += seg_len
		prev = p


func _array_compound_handle_override(item: Dictionary, handle_id: String) -> Dictionary:
	if item.is_empty() or str(item.get("type", "")) != "compound":
		return {}
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(specs.get("compound_kind", "")) != "array":
		return {}
	if handle_id in ["positive", "negative"]:
		return {}
	# Legacy multi-port handles collapse to one bus per polarity.
	if handle_id.contains("negative"):
		return {"rx": 0.33, "ry": 1.0}
	if handle_id.contains("positive") or handle_id.contains("pv"):
		return {"rx": 0.67, "ry": 1.0}
	return {}


const _HANDLE_ID_ALIASES := {
	"pv-positive": "pvPositive",
	"pv-negative": "pvNegative",
	"pv_positive": "pvPositive",
	"pv_negative": "pvNegative",
	"battery-positive": "batteryPositive",
	"battery-negative": "batteryNegative",
	"battery_positive": "batteryPositive",
	"battery_negative": "batteryNegative",
	"ac-output": "acOutput",
	"ac_output": "acOutput",
}


func _normalize_handle_id(handle_id: String) -> String:
	return str(_HANDLE_ID_ALIASES.get(handle_id, handle_id))


func _is_battery_type(itype: String) -> bool:
	return itype == "battery" or itype == "smartbattery"


func _is_generator_type(itype: String) -> bool:
	return itype == "panel" or itype == "wind" or itype == "hydro"


func _controller_handle_candidates(handle_id: String, peer_type: String,
		conn_polarity: String) -> Array:
	var out: Array = [_normalize_handle_id(handle_id)]
	if handle_id.is_empty():
		return out
	var pos_keys := ["positive", "pv-positive", "pv_positive"]
	var neg_keys := ["negative", "pv-negative", "pv_negative"]
	var bat_pos_keys := pos_keys + ["battery-positive", "battery_positive"]
	var bat_neg_keys := neg_keys + ["battery-negative", "battery_negative"]
	if _is_battery_type(peer_type):
		if handle_id in bat_pos_keys or conn_polarity == "positive":
			out.append("batteryPositive")
		if handle_id in bat_neg_keys or conn_polarity == "negative":
			out.append("batteryNegative")
	elif _is_generator_type(peer_type):
		if handle_id in pos_keys or conn_polarity == "positive":
			out.append("pvPositive")
		if handle_id in neg_keys or conn_polarity == "negative":
			out.append("pvNegative")
	return out


func _lookup_handle_fraction(item: Dictionary, handle_id: String) -> Dictionary:
	for h: Dictionary in (item.get("handles", []) as Array):
		if h.get("id", "") == handle_id:
			if h.has("angle_rad"):
				GraphHubPorts.migrate_handle(h)
				return {
					"rx": float(h.get("rx", 0.5)),
					"ry": float(h.get("ry", 0.5)),
					"angle_rad": float(h.get("angle_rad", 0.0)),
					"hub": true,
				}
			if h.has("rx"):
				return {"rx": float(h["rx"]), "ry": float(h["ry"])}
			var iw := float(item.get("width", 120.0))
			var ih := float(item.get("height", 90.0))
			return {
				"rx": float(h.get("x", 0.0)) / maxf(1.0, iw),
				"ry": float(h.get("y", 0.0)) / maxf(1.0, ih),
			}
	for h: Dictionary in _resolved_handles(item):
		if h.get("id", "") == handle_id:
			if h.has("angle_rad"):
				return {
					"rx": float(h.get("rx", 0.5)),
					"ry": float(h.get("ry", 0.5)),
					"angle_rad": float(h.get("angle_rad", 0.0)),
					"hub": true,
				}
			return {"rx": float(h.get("rx", 0.5)), "ry": float(h.get("ry", 0.5))}
	return {}


## Returns {pos: Vector2, tangent: Vector2} for a named handle on an item,
## or {} if the item or handle cannot be found.
func _get_handle_info(item_id: String, handle_id: String,
		center: Vector2, peer_item_id: String = "",
		conn_polarity: String = "") -> Dictionary:
	if model == null or item_id.is_empty() or handle_id.is_empty():
		return {}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {}

	var tl    := _item_screen_tl(item, center)
	var sz    := _item_screen_size(item)
	var itype := item.get("type", "generic") as String
	var peer_type := ""
	if not peer_item_id.is_empty():
		peer_type = str(model.get_item(peer_item_id).get("type", ""))

	var candidates: Array = [handle_id]
	if itype == "controller" and not peer_type.is_empty():
		candidates = _controller_handle_candidates(handle_id, peer_type, conn_polarity)
	else:
		candidates = [_normalize_handle_id(handle_id)]

	var rx := 0.5
	var ry := 0.5
	var angle_rad := NAN
	var found := false
	for cand_v: Variant in candidates:
		var cand: String = _normalize_handle_id(str(cand_v))
		var frac: Dictionary = _lookup_handle_fraction(item, cand)
		if frac.is_empty():
			continue
		rx = float(frac.get("rx", 0.5))
		ry = float(frac.get("ry", 0.5))
		if frac.has("angle_rad"):
			angle_rad = float(frac.get("angle_rad", 0.0))
		found = true
		break

	if not found:
		return {}
	var arr_override := _array_compound_handle_override(item, handle_id)
	if not arr_override.is_empty():
		rx = float(arr_override.get("rx", rx))
		ry = float(arr_override.get("ry", ry))
		angle_rad = NAN

	if GraphHubPorts.is_hub_type(itype) and not is_nan(angle_rad):
		return {
			"pos":     GraphHubPorts.screen_pos_on_circle(tl, sz, angle_rad),
			"tangent": GraphHubPorts.outward_tangent(angle_rad),
		}

	return {
		"pos":     tl + Vector2(sz.x * rx, sz.y * ry),
		"tangent": _tangent_from_rx_ry(rx, ry),
	}


## Infers the outgoing tangent direction from a handle's fractional position.
func _tangent_from_rx_ry(rx: float, ry: float) -> Vector2:
	if rx <= 0.01:   return Vector2(-1.0,  0.0)  # left edge
	if rx >= 0.99:   return Vector2( 1.0,  0.0)  # right edge
	if ry <= 0.01:   return Vector2( 0.0, -1.0)  # top edge
	if ry >= 0.99:   return Vector2( 0.0,  1.0)  # bottom edge
	# Interior port (not on an edge): face the nearest edge rather than always
	# assuming RIGHT, so vertically-placed interior ports still route up/down.
	var d_left := rx
	var d_right := 1.0 - rx
	var d_top := ry
	var d_bottom := 1.0 - ry
	var m := minf(minf(d_left, d_right), minf(d_top, d_bottom))
	if m == d_top:      return Vector2( 0.0, -1.0)
	if m == d_bottom:   return Vector2( 0.0,  1.0)
	if m == d_left:     return Vector2(-1.0,  0.0)
	return Vector2(1.0, 0.0)


## Hit-tests connections by sampling each bezier. Returns the first connection
## whose curve passes within PICK_DIST pixels of screen_pos, or {}.
func _connection_at_screen(screen_pos: Vector2) -> Dictionary:
	if model == null:
		return {}
	const PICK_DIST := 8.0
	var center := size * 0.5

	for conn: Dictionary in _visible_connections():
		var sid: String = conn.get("source_item_id", "") as String
		var tid: String = conn.get("target_item_id", "") as String
		var pol: String = conn.get("polarity", "positive") as String
		var src := _get_handle_info(
			sid, conn.get("source_handle_id", "") as String, center, tid, pol)
		var tgt := _get_handle_info(
			tid, conn.get("target_handle_id", "") as String, center, sid, pol)
		if src.is_empty() or tgt.is_empty():
			continue

		var from:  Vector2 = src["pos"]
		var to:    Vector2 = tgt["pos"]
		var tgt_t_in := _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)
		var wps: Array = _waypoints_screen(conn, center)
		var style: String = str(conn.get("line_style", "bezier"))
		var curve_t := _conn_curve_tension(conn)
		var hit := false
		if style == "orthogonal":
			var poly := _connection_polyline_screen(conn, center, true)
			for i: int in range(poly.size() - 1):
				for s: int in range(9):
					var t: float = float(s) / 8.0
					if _point_segment_distance(
							screen_pos, poly[i], poly[i].lerp(poly[i + 1], t)) < PICK_DIST:
						hit = true
						break
				if hit:
					break
		elif style == "metro":
			var poly := PackedVector2Array()
			if wps.size() == 0:
				var mid_y := (from.y + to.y) * 0.5
				poly.append(from)
				poly.append(Vector2(from.x, mid_y))
				poly.append(Vector2(to.x, mid_y))
				poly.append(to)
			else:
				poly.append(from)
				for wp in wps:
					poly.append(wp as Vector2)
				poly.append(to)
			for i: int in range(poly.size() - 1):
				for s: int in range(9):
					var t: float = float(s) / 8.0
					if _point_segment_distance(
							screen_pos, poly[i], poly[i].lerp(poly[i + 1], t)) < PICK_DIST:
						hit = true
						break
				if hit:
					break
		elif wps.is_empty():
			var ctrl := _wire_bezier_controls(
				from, src.get("tangent", Vector2.RIGHT) as Vector2, to, tgt_t_in, curve_t)
			for i in range(17):
				var t := float(i) / 16.0
				if from.bezier_interpolate(ctrl["c1"], ctrl["c2"], to, t).distance_to(screen_pos) < PICK_DIST:
					hit = true
					break
		else:
			var pts: Array = [from] + wps + [to]
			for i in range(33):
				var t := float(i) / 32.0
				if _sample_wire_path(pts, [src.get("tangent", Vector2.RIGHT), tgt_t_in], t, curve_t).distance_to(screen_pos) < PICK_DIST:
					hit = true
					break
		if hit:
			return conn
	return {}


# ---------------------------------------------------------------------------
# Drawing — top-level dispatch
# ---------------------------------------------------------------------------

## Alpha for the canvas background — driven by the graph view transparency
## slider historically; now also lowered when the live SoI preview is on.
var canvas_bg_alpha: float = 1.0
## When true, skip the filled SoI disc (live SubViewport shows through) and
## only draw the ring / elevation guide.
var soi_live_preview: bool = false

func _draw() -> void:
	_controller_reset_rects.clear()
	_alert_seen_this_draw = false
	# Populate the per-draw visible-items/connections cache for this whole pass
	# (base + any V2 super._draw extension). Refreshed every draw so moves/adds
	# show up; the model is immutable within a single draw.
	_cached_visible_items = _compute_visible_items()
	_cached_visible_connections = _compute_visible_connections()
	_draw_cache_active = true
	var fill := Color(C_CANVAS_BG.r, C_CANVAS_BG.g, C_CANVAS_BG.b, C_CANVAS_BG.a * canvas_bg_alpha)
	if soi_live_preview:
		_draw_canvas_fill_with_soi_hole(fill)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), fill)
	_draw_dot_grid()
	_draw_soi_background()
	_draw_unplaced_tray()

	if model != null and _visible_items().size() > 0:
		_draw_connections()
		for item: Dictionary in _visible_items():
			_render_item(item)
		for item: Dictionary in _visible_items():
			_draw_item_overlays(item)
		for item2: Dictionary in _visible_items():
			_draw_resize_handle(item2)
	# Derive alert presence from what we actually drew, so tick() can pick a
	# coarse animation cadence without a separate model scan. If the state just
	# appeared, kick one redraw so the pulse cadence engages immediately.
	if _alert_seen_this_draw and not _alert_nodes_present:
		queue_redraw()
	_alert_nodes_present = _alert_seen_this_draw
	# Cache stays populated on the instance; a V2 override re-enables it for its
	# extra passes (arrays are still valid — model can't change between passes).
	_draw_cache_active = false

	_draw_destroy_fx()
	_draw_temp_wire()                # always on top of everything
	if _marquee_selecting:
		var rect := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.14), true)
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65), false, 1.6)


# ---------------------------------------------------------------------------
# Model-driven item rendering
# ---------------------------------------------------------------------------

## Item id -> seconds remaining of automation-fire flash pulse.
var _item_flash: Dictionary = {}
const ITEM_FLASH_SECONDS := 0.8

## Pulse a node's border (called when an automation bound to it fires).
func flash_item(item_id: String) -> void:
	if item_id.is_empty():
		return
	_item_flash[item_id] = ITEM_FLASH_SECONDS
	_needs_continuous_redraw = true
	queue_redraw()


## Post-render overlay pass — runs for EVERY visible item regardless of which
## renderer (V1 base or V2 override) drew the body:
##   · ⚙ badge when the item has automation rules bound
##   · pulsing border while an automation fire flash is active
func _draw_item_overlays(item: Dictionary) -> void:
	var iid := str(item.get("id", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)

	var autos: Array = specs.get("graph_automations", []) as Array
	if not autos.is_empty():
		var fnt := ThemeDB.fallback_font
		var fs_ideal := minf(12.0 * _zoom, minf(sz.x, sz.y) * 0.35)
		if fs_ideal >= 5.0:
			var fs := clampi(int(round(fs_ideal)), 5, 28)
			draw_string(fnt, tl + Vector2(3.0 * _zoom, float(fs) + 2.0 * _zoom),
				"⚙", HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.85))

	if _item_flash.has(iid):
		var t := clampf(float(_item_flash[iid]) / ITEM_FLASH_SECONDS, 0.0, 1.0)
		var pulse := 0.35 + 0.65 * absf(sin(t * PI * 3.0))
		draw_rect(Rect2(tl, sz).grow(3.0 * _zoom),
			Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.75 * t * pulse),
			false, maxf(1.5, 3.0 * _zoom))

	# Unified node-state feedback — runs for every node in BOTH V1 and V2 (V2's
	# _draw calls super._draw, which calls this). Draws the bold red/amber pulse,
	# a reason chip, and procedural smoke for faults.
	_draw_node_state_overlay(item, specs, Rect2(tl, sz))


## Bold, type-agnostic state overlay driven by specs["node_state"]. Nominal
## (running / idle / unset) draws nothing here — the RUNNING glow lives in the
## body pass. Alert states get a pulsing outline + halo, a reason chip, and (for
## faults) a rising procedural smoke plume that tracks pan/zoom every frame.
func _draw_node_state_overlay(item: Dictionary, specs: Dictionary, rect: Rect2) -> void:
	var state := str(specs.get("node_state", ""))
	# Controllers flag faults via the legacy `destroyed` spec — treat that as
	# FAULT so they gain the chip + pulse without a separate view write.
	var destroyed := bool(specs.get("destroyed", false))
	if destroyed and not GraphNodeState.is_alert(state):
		state = GraphNodeState.FAULT
	# READY is nominal: a quiet static chip only — no pulse, glow, or animation.
	if GraphNodeState.is_ready(state):
		var rc := GraphNodeState.state_color(state)
		var rchip := (GraphNodeState.state_icon(state) + " "
				+ GraphNodeState.chip_text(state)).strip_edges()
		if not rchip.is_empty():
			_state_badge.draw_badge(self, rect, rchip, rc, _zoom)
		return
	if not GraphNodeState.is_alert(state):
		return
	# Flag that an alert node was drawn — tick() reads _alert_nodes_present to run
	# a coarse ~10 fps pulse cadence instead of the 20 fps interactive loop, so a
	# faulted node no longer pins the canvas at full redraw rate while paused.
	_alert_seen_this_draw = true
	var col := GraphNodeState.state_color(state)
	var pulse := 0.45 + 0.55 * absf(sin(_alert_phase * TAU))
	var grow := maxf(3.0, 5.0 * _zoom)
	draw_rect(rect.grow(grow * 0.6), Color(col.r, col.g, col.b, 0.16 * pulse), true)
	draw_rect(rect.grow(grow), Color(col.r, col.g, col.b, 0.9 * pulse),
		false, maxf(2.0, 3.0 * _zoom))

	# Bespoke controller-destroy FX already renders its own smoke burst; only
	# add the procedural plume for other faulted nodes.
	if state == GraphNodeState.FAULT and not destroyed:
		_draw_fault_smoke(rect)

	var reason := str(specs.get("node_state_reason", ""))
	if destroyed and reason.is_empty():
		reason = GraphNodeState.REASON_OVERVOLTAGE
	var kinds: Array = specs.get("node_state_kinds", []) as Array
	var chip := (GraphNodeState.state_icon(state) + " "
			+ GraphNodeState.chip_text(state, reason, kinds)).strip_edges()
	if not chip.is_empty():
		_state_badge.draw_badge(self, rect, chip, col, _zoom)


## Continuous rising smoke plume above a faulted node. Purely procedural (no
## spawn/aging state), so it correctly follows pan and zoom each frame.
func _draw_fault_smoke(rect: Rect2) -> void:
	var base := Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y)
	var puffs := 5
	for i in puffs:
		var ph := fmod(_alert_phase * 0.6 + float(i) / float(puffs), 1.0)
		var rise := (16.0 + 46.0 * ph) * _zoom
		var drift := sin((ph + float(i)) * 3.1) * 9.0 * _zoom
		var pos := base + Vector2(drift, -rise)
		var r := maxf(1.5, (3.5 + 9.0 * ph) * _zoom)
		var a := (1.0 - ph) * 0.45
		draw_circle(pos, r, Color(0.32, 0.31, 0.33, a))


func _render_item(item: Dictionary) -> void:
	var itype   := item.get("type", "generic") as String
	var center  := size * 0.5
	var tl_orig := _item_screen_tl(item, center)
	var sz_orig := _item_screen_size(item)
	var tl      := tl_orig
	var sz      := sz_orig
	var iid: String = item.get("id", "") as String
	var is_sel: bool = (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs   := item.get("specs", {}) as Dictionary

	# Site / elevation: always draw map-scaled footprints (never freeform cards —
	# those ignored physical metres and fought zoom). Unplaced → tray chips.
	if _is_physical_view():
		_draw_site_plan_chip(item, Rect2(tl, sz), is_sel)
		return

	if itype in ["battery", "smartbattery", "resource"]:
		var level: float = clampf(float(specs.get("soc", specs.get("level", 0.0))), 0.0, 1.0)
		var do_balloon := itype != "resource" or bool(specs.get("scale_with_fill", true))
		if do_balloon:
			var scale_factor = 1.0 + (level * 0.15)
			sz = sz_orig * scale_factor
			tl = tl_orig - (sz - sz_orig) * 0.5
		
	var rect    := Rect2(tl, sz)

	if itype in ["battery", "smartbattery", "resource"]:
		var level: float = clampf(float(specs.get("soc", specs.get("level", 0.0))), 0.0, 1.0)
		# Unlimited / conceptual tanks skip the near-full alert pulse.
		if itype == "resource" and bool(specs.get("unlimited_capacity", false)):
			pass
		else:
			var alert_threshold = float(specs.get("alert_threshold_pct", 95.0)) / 100.0
			if level >= alert_threshold:
				var wave_count = 3
				for w in wave_count:
					var wave_phase = fmod(_flow_phase * 1.5 + float(w) / wave_count, 1.0)
					var wave_expand = maxf(5.0, 30.0 * _zoom) * wave_phase
					var wave_rect = rect.grow(wave_expand)
					var alpha = (1.0 - wave_phase) * 0.6
					draw_rect(wave_rect, Color(1.0, 0.2, 0.2, alpha), false, 2.0 * _zoom)

	# Active-load glow / blocked vibration (behind frame), driven by the unified
	# node state. Blocked-family states jitter the body + red glow; RUNNING gets
	# the green active glow. (The pulsing outline + chip come from the overlay pass.)
	var node_state := str(specs.get("node_state", ""))
	if GraphNodeState.is_blocked_family(node_state):
		var offset = Vector2(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0)) * _zoom
		tl += offset
		rect.position += offset
		var glow := rect.grow(maxf(2.5, 3.0 * _zoom))
		draw_rect(glow, Color(0.9, 0.15, 0.2, 0.35), true)
	elif node_state == GraphNodeState.RUNNING:
		var glow := rect.grow(maxf(2.5, 3.0 * _zoom))
		draw_rect(glow, C_ACTIVE_LOAD_GLOW, true)
	elif itype in ["appliance", "acload", "processor"]:
		# Legacy fallback for load nodes not driven by the resource engine.
		var st := str(specs.get("current_state", "")).to_lower()
		var avg := float(specs.get("avg_watts", 0.0))
		if st == "on" or (st.is_empty() and avg > 0.5):
			var glow := rect.grow(maxf(2.5, 3.0 * _zoom))
			draw_rect(glow, C_ACTIVE_LOAD_GLOW, true)

	# Node background + border
	if itype == "pbi":
		_draw_pbi_body(rect, specs, item)
		_draw_item_handles(item, tl_orig, sz_orig)
		if is_sel:
			var center_pt = rect.position + rect.size * 0.5
			var rad = minf(rect.size.x, rect.size.y) * 0.5 + 4.0 * _zoom
			draw_arc(center_pt, rad, 0, TAU, 32, C_PRIMARY, 2.0 * _zoom)
		return

	# Node background + border
	var border_col := NODE_BORDER_COLORS.get(itype, C_BORDER) as Color

	if bool(item.get("is_ghost", false)):
		border_col = Color(border_col.r, border_col.g, border_col.b, 0.45)
	if is_sel:
		border_col = C_SELECTED_BORDER
	if itype == "controller" and bool(specs.get("destroyed", false)):
		border_col = Color(0.95, 0.25, 0.25, 1.0)

	# Icon / GLB preview replaces the frame + title when requested (default on
	# for items that carry a model_id or icon glyph).
	if _icon_replaces_frame(specs):
		_draw_icon_as_node(rect, specs, border_col, is_sel)
		_draw_item_handles(item, tl_orig, sz_orig)
		if is_sel:
			draw_rect(rect.grow(maxf(1.0, 1.5 * _zoom)),
				Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.14), true)
			draw_rect(rect.grow(maxf(0.5, 1.0 * _zoom)),
				Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.9), false,
				maxf(1.0, 1.4 * _zoom))
		return

	_draw_node_frame(rect, border_col)

	# Title band
	var title_h := _title_band_height(sz.y)
	var title   := _type_title(itype, specs)
	_draw_title_band(rect, title_h, title, border_col)

	# Body content
	var body_rect := Rect2(tl + Vector2(0.0, title_h), sz - Vector2(0.0, title_h))
	match itype:
		"panel":
			_draw_panel_body(body_rect, specs)
		"wind":
			_draw_wind_body(body_rect, specs)
		"hydro":
			_draw_hydro_body(body_rect, specs)
		"battery", "smartbattery":
			_draw_battery_body(body_rect, specs)
		"controller":
			_draw_controller_body(body_rect, specs, iid, rect)
		"compound":
			_draw_compound_body(body_rect, specs)
		"appliance", "acload":
			_draw_load_body(body_rect, specs)
		"processor":
			_draw_processor_body(body_rect, specs)
		"resource":
			_draw_resource_body(body_rect, specs, item)
		"catchment":
			_draw_catchment_body(body_rect, specs)
		"plant":
			_draw_plant_body(body_rect, specs)
		"shelly4pm", "spiderbox", "breaker_panel":
			_draw_shelly4pm_body(body_rect, specs)
		_:
			_draw_generic_body(body_rect, specs)

	# Live / Sim data-source badge — shows whether the wattage / soc / state
	# currently displayed comes from real HA pushes or from the in-game
	# simulation.  Only meaningful for data-bearing node types.
	if itype in ["panel", "battery", "smartbattery", "controller",
			"appliance", "acload", "shelly4pm", "spiderbox", "breaker_panel"]:
		_draw_data_source_badge(rect, specs)

	# Port dots
	_draw_item_handles(item, tl_orig, sz_orig)

	# Selection glow (cyan tint)
	if is_sel:
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.12))


## Right-edge of title-band badge that signals where the values currently
## drawn on this node are coming from:
##   📡 (green)  — LIVE HA push
##   🕒 (amber)  — HISTORICAL replay
##   💻 (muted)  — SIMULATOR / no HA link
##
## The badge sits in the title band's right-hand padding, so it never
## collides with the body content (wattages, SOC bars, circuit rows, …).
func _draw_data_source_badge(rect: Rect2, specs: Dictionary) -> void:
	var ha_live: Dictionary = (specs.get("ha_live", {}) as Dictionary)
	var fnt   := ThemeDB.fallback_font
	var sm := _cached_autoload("/root/SimMode")
	var icon_str: String = "💻"
	var icon_col: Color = C_TEXT_M
	if sm != null and not ha_live.is_empty():
		if bool(sm.call("is_live")):
			icon_str = "📡"
			icon_col = Color(0.27, 0.9, 0.42)
		elif bool(sm.call("is_historical")):
			icon_str = "🕒"
			icon_col = C_AMBER
	# Match the title band's vertical centring (see _draw_title_band) so the
	# badge sits on the same baseline as the type label.
	var band_h: float = _title_band_height(rect.size.y)
	var fsize_b := _fit_title_font_size(band_h)
	var cy: float = rect.position.y + band_h * 0.5 + fsize_b * 0.38
	var pos := Vector2(rect.position.x + rect.size.x - fsize_b - 8.0, cy)
	draw_string(fnt, pos, icon_str,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize_b, icon_col)


func _draw_node_frame(rect: Rect2, border_col: Color) -> void:
	_sb_node_base.bg_color     = C_PANEL_BG
	_sb_node_base.border_color = border_col
	draw_style_box(_sb_node_base, rect)


## True when the node should be drawn as a full-bleed icon/preview (no title band).
## Default ON when a GLB model_id is present; emoji-only nodes opt in via
## specs.icon_replaces_frame = true.
func _icon_replaces_frame(specs: Dictionary) -> bool:
	var has_model := not str(specs.get("model_id", "")).is_empty()
	var has_icon := not str(specs.get("icon", "")).is_empty()
	if not has_model and not has_icon:
		return false
	if specs.has("icon_replaces_frame"):
		return bool(specs.get("icon_replaces_frame"))
	return has_model


## Full-node icon or GLB preview; ports + selection still drawn by the caller.
func _draw_icon_as_node(rect: Rect2, specs: Dictionary, border_col: Color,
		is_sel: bool) -> void:
	var z := _zoom
	var pad := maxf(2.0, 3.0 * z)
	# Soft shadow + transparent plate (no title band).
	draw_rect(Rect2(rect.position + Vector2(1.5 * z, 2.0 * z), rect.size),
		Color(0, 0, 0, 0.35), true)
	draw_rect(rect, Color(0.04, 0.06, 0.10, 0.55), true)
	draw_rect(rect, Color(border_col.r, border_col.g, border_col.b,
		0.85 if is_sel else 0.45), false, maxf(1.0, 1.2 * z))
	var inner := rect.grow(-pad)
	if _draw_model_preview_zone(inner, specs, 1.0):
		return
	var icon := str(specs.get("icon", ""))
	if icon.is_empty():
		icon = "⚙"
	var fnt := ThemeDB.fallback_font
	var fs := int(clampf(minf(inner.size.x, inner.size.y) * 0.62, 8.0, 240.0))
	var isz := fnt.get_string_size(icon, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos := inner.position + (inner.size - isz) * 0.5 + Vector2(0.0, fs * 0.72)
	draw_string(fnt, pos, icon, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.95, 0.97, 1.0, 0.96))


func _draw_title_band(rect: Rect2, band_h: float, title: String,
		accent: Color) -> void:
	var band := Rect2(rect.position, Vector2(rect.size.x, band_h))
	draw_rect(band, Color(accent.r, accent.g, accent.b, 0.20))
	draw_rect(Rect2(band.position, Vector2(band.size.x, 1.5)), Color(accent.r, accent.g, accent.b, 0.55))
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_title_font_size(band_h)
	var cy    := rect.position.y + band_h * 0.5 + fsize * 0.38
	var pad_x := 10.0
	var max_w := maxf(8.0, rect.size.x - pad_x * 2.0 - 20.0)
	_draw_fitted_label(
		Vector2(rect.position.x + pad_x, cy),
		title, max_w, fsize, Color(0.92, 0.95, 0.99, 1.0))


func _draw_wind_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt: Font = ThemeDB.fallback_font
	var inner: Rect2 = rect.grow(-4.0)
	var fsize: int = _fit_font_size(inner, 4, 9.0, 11.0)
	if inner.size.x < 4.0 or inner.size.y < 4.0:
		return
	var out_kw := float(specs.get("current_output_kw", 0.0))
	var producing := out_kw > 0.0001

	var used_preview := _draw_model_preview_zone(inner, specs, 0.48)
	if not used_preview:
		# Rotor glyph: hub + three blades, spun by the flow phase when producing.
		var hub := Vector2(inner.position.x + inner.size.x * 0.26,
			inner.position.y + inner.size.y * 0.40)
		var blade_len := minf(inner.size.y * 0.34, inner.size.x * 0.22)
		var col := NODE_BORDER_COLORS.get("wind", C_TEXT) as Color
		var spin := _flow_phase * 2.2 if producing else 0.0
		for b in 3:
			var ang := spin + float(b) * TAU / 3.0
			draw_line(hub, hub + Vector2(cos(ang), sin(ang)) * blade_len,
				Color(col.r, col.g, col.b, 0.9 if producing else 0.45), 2.0)
		draw_circle(hub, 3.0, col)
		# Tower
		draw_line(hub, Vector2(hub.x, inner.end.y - 2.0),
			Color(col.r, col.g, col.b, 0.5), 2.0)

	# Readouts at right
	var tx := inner.position.x + inner.size.x * 0.50
	var y := inner.position.y + fsize
	draw_string(fnt, Vector2(tx, y), "Out %.0f W" % (out_kw * 1000.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1, C_AMBER if producing else C_TEXT_M)
	y += fsize + 3.0
	draw_string(fnt, Vector2(tx, y), "⌀ %.1f m" % float(specs.get("rotor_diameter_m", 2.1)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 2.0
	draw_string(fnt, Vector2(tx, y), "hub %.0f m" % float(specs.get("hub_height_m", 10.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 2.0
	draw_string(fnt, Vector2(tx, y), "%.0f W max" % float(specs.get("rated_w", 1000.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_M)


func _draw_hydro_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt: Font = ThemeDB.fallback_font
	var inner: Rect2 = rect.grow(-4.0)
	var fsize: int = _fit_font_size(inner, 4, 9.0, 11.0)
	if inner.size.x < 4.0 or inner.size.y < 4.0:
		return
	var out_kw := float(specs.get("current_output_kw", 0.0))
	var producing := out_kw > 0.0001
	var col := NODE_BORDER_COLORS.get("hydro", C_TEXT) as Color

	var used_preview := _draw_model_preview_zone(inner, specs, 0.48)
	if not used_preview:
		# Penstock glyph: sloped pipe into a runner wheel, ripple when producing.
		var top := Vector2(inner.position.x + 6.0, inner.position.y + 6.0)
		var wheel := Vector2(inner.position.x + inner.size.x * 0.26, inner.end.y - 12.0)
		draw_line(top, wheel, Color(col.r, col.g, col.b, 0.7), 3.0)
		draw_circle(wheel, 7.0, Color(col.r, col.g, col.b, 0.25))
		draw_circle(wheel, 7.0, col, false, 1.5)
		if producing:
			var ripple := 7.0 + 3.0 * (0.5 + 0.5 * sin(_flow_phase * 3.0))
			draw_circle(wheel, ripple, Color(col.r, col.g, col.b, 0.35), false, 1.0)

	# Readouts at right
	var tx := inner.position.x + inner.size.x * 0.50
	var y := inner.position.y + fsize
	draw_string(fnt, Vector2(tx, y), "Out %.0f W" % (out_kw * 1000.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1, C_AMBER if producing else C_TEXT_M)
	y += fsize + 3.0
	draw_string(fnt, Vector2(tx, y), "head %.1f m" % float(specs.get("gross_head_m", 25.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 2.0
	draw_string(fnt, Vector2(tx, y), "%.1f L/s" % float(specs.get("design_flow_lps", 3.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 2.0
	var kind := str(specs.get("kind", "pelton")).replace("_", "-")
	draw_string(fnt, Vector2(tx, y), kind,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_M)


func _draw_panel_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt: Font     = ThemeDB.fallback_font
	var pad: float  = 4.0
	var inner: Rect2  = rect.grow(-pad)
	var fsize: int  = _fit_font_size(inner, 3, 9.0, 11.0)
	if inner.size.x < 4.0 or inner.size.y < 4.0:
		return
	# Visually “PV modules”: most of the body, stats on the right
	var split: float  = maxf(52.0, inner.size.x * 0.56)
	var grid_r: Rect2  = Rect2(
		inner.position, Vector2(minf(split, inner.size.x * 0.7), inner.size.y))
	_draw_solar_array_skin(grid_r)
	# Readouts at right
	var tx:  float  = grid_r.end.x + 6.0
	var y:  float  = inner.position.y + fsize
	var name_ := (specs.get("name", "Array") as String)
	if y + fsize * 3.0 > inner.end.y - 2.0:
		tx  = inner.position.x + 5.0
		y  = grid_r.end.y - fsize * 2.0 - 4.0
	draw_string(
		fnt, Vector2(tx, y), name_.substr(0, 22) if name_.length() > 22 else name_,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y  += fsize + 2.0
	var wmp:  float  = float(specs.get("wmp", 0.0))
	draw_string(fnt, Vector2(tx, y), "Σ %.0f W" % wmp,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1, C_TEXT)
	y  += fsize + 2.0
	var out_kw: float  = float(specs.get("current_output_kw", 0.0))
	if out_kw > 0.0001 or wmp > 0.0:
		draw_string(fnt, Vector2(tx, y), "Out %.0f W" % (out_kw * 1000.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_AMBER)
		y  += fsize + 2.0
	var voc:  float  = float(specs.get("voc", 0.0))
	var vmp:  float  = float(specs.get("vmp", 0.0))
	if voc > 0.0 and y < inner.end.y - 1.0:
		draw_string(fnt, Vector2(tx, y), "Voc %.0f  Vmp %.0f" % [voc, vmp],
			HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), C_TEXT_M)


## Grid of “cells” + bus bars to read as a small PV string.
func _draw_solar_array_skin(r: Rect2) -> void:
	var frame_c: Color  = Color(0.4, 0.48, 0.55, 0.95)
	var bg: Color  = Color(0.04, 0.09, 0.2)
	var cell := Color(0.1, 0.2, 0.38)
	var bus_pos := Color(0.9, 0.35, 0.25, 0.95)
	var bus_neg := Color(0.3, 0.32, 0.4, 0.9)
	# Chassis
	draw_rect(r, bg, true)
	draw_rect(r, frame_c, false)
	# 3×2 “modules”
	var gmar:  float  = 3.0
	var mod_r:  Rect2  = r.grow(-gmar)
	if mod_r.size.x < 8.0 or mod_r.size.y < 8.0:
		return
	var cols: int  = 3
	var rows:  int  = 2
	var cell_w: float  = (mod_r.size.x - 4.0) / float(cols)
	var cell_h: float  = (mod_r.size.y - 10.0) / float(rows) # leave bus strip
	for c in range(cols):
		for rr in range(rows):
			var cpos:  Vector2 = mod_r.position + Vector2(
				2.0 + float(c) * cell_w, 2.0 + float(rr) * cell_h)
			var cr:  Rect2  = Rect2(cpos, Vector2(maxf(2.0, cell_w - 1.0), maxf(2.0, cell_h - 1.0)))
			# Slight 3/4 “sun” sheen (top cell edge brighter)
			var hi: float  = 0.08 * float(1 - rr)
			var fill:  Color  = cell.lerp(Color(0.22, 0.42, 0.7), hi)
			draw_rect(cr, fill, true)
			# bus ribbon within cell (horizontal micro-lines)
			for k in 3:
				var ly: float  = cpos.y + 4.0 + float(k) * (cell_h * 0.2)
				draw_line(Vector2(cpos.x + 2, ly), Vector2(cpos.x + cr.size.x - 2, ly),
					Color(0.0, 0.0, 0.0, 0.25), 0.5)
			draw_rect(cr, Color(0.55, 0.65, 0.8, 0.35), false)
	# Bottom j-box / bus
	var bus_y:  float  = mod_r.end.y - 4.0
	var bus:  Rect2  = Rect2(Vector2(mod_r.position.x + 1.0, bus_y - 1.0),
		Vector2(mod_r.size.x - 2.0, 3.0))
	draw_rect(bus, bus_neg, true)
	var midx:  float  = bus.position.x + bus.size.x * 0.5
	draw_line(Vector2(bus.position.x + 1.0, bus_y), Vector2(midx - 3.0, bus_y), bus_pos, 1.2)
	draw_line(Vector2(midx + 3.0, bus_y), Vector2(bus.end.x - 1.0, bus_y), C_TEXT_S, 1.0)


func _draw_v_gradient_fill(r: Rect2, c_bot: Color, c_top: Color) -> void:
	if r.size.y < 0.5:
		return
	var n: int  = 12
	var hseg:  float  = r.size.y / float(n)
	for i in n:
		var t:  float  = float(i) / float(max(1, n - 1)) # i=0 bottom, i=n-1 top
		var c:  Color  = c_bot.lerp(c_top, t)
		# i=0: strip at bottom of rect
		var y0: float  = r.end.y - hseg * float(i + 1)
		var sh:  float  = hseg + 0.25
		draw_rect(Rect2(Vector2(r.position.x, y0), Vector2(r.size.x, sh)), c, true)


func _draw_battery_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt:  Font  = ThemeDB.fallback_font
	var fsize:  int  = _fit_font_size(rect, 3, 10.0, 12.0)
	var pad: float  = 4.0
	var inner: Rect2  = rect.grow(-pad)
	if inner.size.x < 12.0 or inner.size.y < 8.0:
		return
	# Wide vertical SOC on the left, text on the right
	var bar_w:  float  = clampf(inner.size.x * 0.26, 20.0, 44.0)
	var bar_r:  Rect2  = Rect2(inner.position, Vector2(bar_w, inner.size.y))
	var track: Color  = Color(0.04, 0.07, 0.1)
	var soc:  float  = float(specs.get("soc", 0.5))
	soc  = clampf(soc, 0.0, 1.0)
	draw_rect(bar_r, track, true)
	# bevel
	draw_rect(bar_r, Color(0.12, 0.18, 0.28, 0.5), false)
	# fill from bottom
	var h_fill: float  = maxf(1.0, bar_r.size.y * soc)
	var fill:   Rect2  = Rect2(
		Vector2(bar_r.position.x, bar_r.end.y - h_fill),
		Vector2(bar_w, h_fill)
	)
	var c0:  Color  = Color(0.04, 0.42, 0.2)
	var c1:  Color  = C_GREEN.lerp(Color(0.45, 1.0, 0.65), 0.4)
	_draw_v_gradient_fill(fill, c0, c1)
	var sheen_h: float  = minf(2.5, maxf(1.0, fill.size.y * 0.04))
	if sheen_h > 0.4:
		draw_rect(
			Rect2(fill.position, Vector2(fill.size.x, sheen_h)),
			Color(0.55, 1.0, 0.65, 0.3)
		)
	# Text column
	var tx:  float  = bar_r.end.x + 7.0
	var y:  float  = inner.position.y + fsize + 2.0
	var volts:  float  = float(specs.get("voltage", 12.0))
	var ah:  float  = float(specs.get("ah", 0.0))
	var kwh:  float  = float(specs.get("kwh", 0.0))
	draw_string(fnt, Vector2(tx, y), "%.0fV   %.0f Ah" % [volts, ah],
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y  += fsize + 3.0
	draw_string(fnt, Vector2(tx, y), "%.2f / %.2f kWh" % [kwh * soc, kwh], HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_GREEN)
	y  += fsize + 2.0
	if y < inner.end.y - 1.0:
		draw_string(fnt, Vector2(tx, y), "SoC %.0f%%" % (soc * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)


func _draw_controller_body(body_rect: Rect2, specs: Dictionary, item_id: String = "",
		full_rect: Rect2 = Rect2()) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(body_rect, 1, 11.0)
	var x     := body_rect.position.x + 10.0
	var y     := body_rect.position.y + fsize + 6.0
	var name_ := specs.get("name", "MPPT Controller") as String
	var destroyed := bool(specs.get("destroyed", false))
	if destroyed:
		name_ = "DESTROYED"
	draw_string(fnt, Vector2(x, y), name_,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(1.0, 0.35, 0.35) if destroyed else C_TEXT)
	if destroyed:
		var reason := str(specs.get("destroyed_reason", "Over-voltage fault"))
		y += fsize + 4.0
		draw_string(fnt, Vector2(x, y), reason,
			HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 2), C_TEXT_M)
		var btn_w := minf(full_rect.size.x - 20.0, 88.0)
		var btn_h := 22.0
		var btn_rect := Rect2(
			full_rect.position.x + (full_rect.size.x - btn_w) * 0.5,
			full_rect.end.y - btn_h - 8.0, btn_w, btn_h)
		draw_rect(btn_rect, Color(0.15, 0.45, 0.22, 0.95), true)
		draw_rect(btn_rect, Color(0.35, 0.85, 0.45, 0.9), false, 1.5)
		draw_string(fnt, Vector2(btn_rect.position.x + 14.0, btn_rect.end.y - 6.0), "RESET",
			HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(9, fsize), Color(0.9, 1.0, 0.92))
		if not item_id.is_empty():
			_controller_reset_rects[item_id] = btn_rect


func _draw_destroy_fx() -> void:
	var fnt := ThemeDB.fallback_font
	for fx in _destroy_fx:
		if not (fx is Dictionary):
			continue
		var age := float((fx as Dictionary).get("age", 0.0))
		var c: Vector2 = (fx as Dictionary).get("center", Vector2.ZERO)
		var n := 8 + int(age * 6.0)
		for i in n:
			var t := float(i) / float(maxi(n - 1, 1))
			var ang := t * TAU + age * 2.3
			var rad := 8.0 + age * 28.0 + sin(t * 5.0 + age * 3.0) * 6.0
			var p := c + Vector2(cos(ang), sin(ang)) * rad
			var alpha := clampf(1.0 - age / 2.5, 0.0, 0.75) * (1.0 - t * 0.6)
			draw_circle(p, 3.0 + t * 4.0, Color(0.45, 0.45, 0.48, alpha))
		draw_string(fnt, c + Vector2(-36.0, -18.0 - age * 8.0), "💥",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, clampf(1.0 - age / 2.0, 0.0, 1.0)))


func _draw_load_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 2, 11.0)
	var x     := rect.position.x + 10.0
	var y     := rect.position.y + fsize + 6.0
	var name_ := specs.get("name", "Load") as String
	draw_string(fnt, Vector2(x, y), name_,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	# Use avg_watts (live) if present, fall back to watts or max_watts
	var avg_w := float(specs.get("avg_watts", specs.get("watts", specs.get("max_watts", 0.0))))
	var state := specs.get("current_state", "") as String
	# Dim the wattage label when device is off
	var w_color := C_TEXT
	if state == "off" or (state.is_empty() and avg_w <= 0.0 and specs.has("max_watts")):
		w_color = C_TEXT_M
	draw_string(fnt, Vector2(x, y), "%.0f W" % avg_w,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 2, w_color)
	# ON / OFF badge for virtual (bridge-managed) device nodes
	if not state.is_empty():
		var badge := "● ON" if state == "on" else "○ OFF"
		var bcol  := Color(0.27, 0.9, 0.42) if state == "on" else C_TEXT_M
		var bx    := rect.position.x + rect.size.x - 38.0
		draw_string(fnt, Vector2(bx, y), badge,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, bcol)


func _draw_generic_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var inner := rect.grow(-4.0)
	var fsize := _fit_font_size(inner, 1, 10.0)
	var used_preview := _draw_model_preview_zone(inner, specs, 0.42)
	var x := inner.position.x + (inner.size.x * 0.46 if used_preview else 8.0)
	var y := inner.position.y + fsize + 6.0
	var name_ := specs.get("name", "") as String
	if not name_.is_empty():
		draw_string(fnt, Vector2(x, y), name_,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)


func _draw_compound_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 2, 10.0, 11.0)
	var x := rect.position.x + 8.0
	var y := rect.position.y + fsize + 4.0
	var summary: String = specs.get("summary", "Nested graph") as String
	draw_string(fnt, Vector2(x, y), summary,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	var child_count: int = int(specs.get("child_count", 0))
	var port_in: int = int(specs.get("port_in_count", 0))
	var port_out: int = int(specs.get("port_out_count", 0))
	draw_string(fnt, Vector2(x, y), "%d nodes inside" % child_count,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 3.0
	draw_string(fnt, Vector2(x, y), "In %d  Out %d" % [port_in, port_out],
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_M)


## Processor: converts energy + resources into outputs (pump, shredder, reactor…)
func _draw_processor_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var inner := rect.grow(-4.0)
	var fsize := _fit_font_size(inner, 3, 10.0, 12.0)
	var used_preview := _draw_model_preview_zone(inner, specs, 0.42)
	var x := inner.position.x + (inner.size.x * 0.46 if used_preview else 10.0)
	var y := inner.position.y + fsize + 5.0
	var name_ := specs.get("name", "Processor") as String
	draw_string(fnt, Vector2(x, y), name_,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	var es: String = str(specs.get("energy_source", "ac"))
	if es.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		es = "ac"
	if es == "ac":
		draw_string(fnt, Vector2(x, y), "⚡ AC in (top port)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_AMBER)
		y += fsize + 2.0
	var watts: float = float(specs.get("watts", specs.get("max_watts", 0.0)))
	if watts > 0.0:
		draw_string(fnt, Vector2(x, y), "%.0f W" % watts,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 2, C_TEXT)
		y += fsize + 4.0
	var rate_str: String = specs.get("output_rate", "") as String
	if not rate_str.is_empty():
		draw_string(fnt, Vector2(x, y), rate_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_M)
	for dc_o: Variant in (specs.get("outputs", []) as Array):
		if dc_o is Dictionary and str((dc_o as Dictionary).get("kind", "")) == "dc_electricity":
			var dc_w: float = float(specs.get("current_output_kw", 0.0)) * 1000.0
			draw_string(fnt, Vector2(x, y), "⚡ %.0f W" % dc_w,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1,
				C_AMBER if dc_w > WIRE_DEAD_W else C_TEXT_M)
			y += fsize + 4.0
			break


## Draw a cached GLB card snapshot in the left zone of a node body.
## Returns true when a texture was drawn (caller should skip procedural glyph).
func _draw_model_preview_zone(inner: Rect2, specs: Dictionary, width_frac: float = 0.48) -> bool:
	if model_preview_service == null or not is_instance_valid(model_preview_service):
		return false
	if str(specs.get("model_id", "")).is_empty():
		return false
	if not model_preview_service.has_method("get_or_request"):
		return false
	var tex: ImageTexture = model_preview_service.call("get_or_request", specs) as ImageTexture
	if tex == null:
		return false
	var zone_w := maxf(24.0, inner.size.x * width_frac)
	var zone := Rect2(inner.position, Vector2(zone_w, inner.size.y))
	# Keep aspect: fit texture inside zone, centered.
	var tex_sz := tex.get_size()
	if tex_sz.x < 1.0 or tex_sz.y < 1.0:
		return false
	var scale := minf(zone.size.x / tex_sz.x, zone.size.y / tex_sz.y)
	var draw_sz := tex_sz * scale
	var draw_pos := zone.position + (zone.size - draw_sz) * 0.5
	draw_texture_rect(tex, Rect2(draw_pos, draw_sz), false)
	return true


## Shelly Pro 4PM: four metered 16 A AC circuits with on/off state and power readings.
func _draw_shelly4pm_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var pad   := 5.0
	var inner := rect.grow(-pad)
	var fsize := _fit_font_size(inner, 2, 9.0, 11.0)
	if inner.size.y < 16.0 or inner.size.x < 24.0:
		return

	# Total power header
	var total_w := 0.0
	for ci: int in 4:
		total_w += float(specs.get("c%d_power_w" % ci, 0.0))
	var y := inner.position.y + fsize + 1.0
	draw_string(fnt, Vector2(inner.position.x, y),
		"Total  %.0f W" % total_w,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_AMBER)
	y += fsize + 5.0

	# Four circuit rows
	var rows_h   := inner.end.y - y
	var row_h    := maxf(14.0, rows_h / 4.0)
	var dot_r    := maxf(3.0, 3.5 * sqrt(_zoom))
	var accent   := Color(0.588, 0.322, 0.933, 1.0)   # matches shelly4pm border

	for ci: int in 4:
		var ci_name  := specs.get("c%d_name" % ci, "Ckt %d" % ci) as String
		var ci_power := float(specs.get("c%d_power_w" % ci, 0.0))
		var ci_on    := bool(specs.get("c%d_on" % ci, false))

		# Row background tint when circuit is live
		if ci_on and ci_power > 0.5:
			draw_rect(
				Rect2(Vector2(inner.position.x, y - fsize - 1.0),
					Vector2(inner.size.x, row_h)),
				Color(accent.r, accent.g, accent.b, 0.10))

		# ON / OFF indicator dot
		var dot_x := inner.position.x + dot_r + 2.0
		var dot_y := y - fsize * 0.25
		var dot_col := Color(0.27, 0.9, 0.42) if ci_on else C_TEXT_M
		draw_circle(Vector2(dot_x, dot_y), dot_r + 1.0,
			Color(dot_col.r, dot_col.g, dot_col.b, 0.30))
		draw_circle(Vector2(dot_x, dot_y), dot_r, dot_col)

		# Circuit name (truncated)
		var name_x := dot_x + dot_r + 5.0
		var name_short := ci_name if ci_name.length() <= 8 else ci_name.substr(0, 8)
		draw_string(fnt, Vector2(name_x, y), name_short,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)

		# Power reading (right-aligned)
		var pw_str  := "%.0fW" % ci_power
		var pw_col  := C_AMBER if ci_on else C_TEXT_M
		var pw_x    := inner.end.x - fsize * pw_str.length() * 0.62
		draw_string(fnt, Vector2(pw_x, y), pw_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, pw_col)

		# Thin separator line
		var line_y := y + (row_h - fsize) * 0.5
		if ci < 3:
			draw_line(
				Vector2(inner.position.x + 2.0, line_y),
				Vector2(inner.end.x - 2.0, line_y),
				Color(accent.r, accent.g, accent.b, 0.18), 0.5)

		y += row_h


## Resource container: stores a non-electrical resource (water, fuel, heat…)
func _draw_resource_body(rect: Rect2, specs: Dictionary, item: Dictionary = {}) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 1, 10.0)
	var pad   := 6.0
	var inner := rect.grow(-pad)
	if inner.size.y < 20.0:
		return

	ResourceKinds.new().migrate_resource_specs(specs)
	var kind: String = str(specs.get("resource_kind", "water"))
	var kind_col: Color = ResourceKinds.wire_color(kind)
	var is_ghost: bool = bool(item.get("is_ghost", false)) or bool(specs.get("is_ghost", false))

	var raw_level: float = float(specs.get("level", 0.5))
	var allow_negative: bool = bool(specs.get("allow_negative", false))
	var in_deficit: bool = allow_negative and raw_level < 0.0
	var level: float = clampf(raw_level, 0.0, 1.0)
	var bar_w: float = inner.size.x
	var bar_h: float = maxf(inner.size.y * 0.55, 12.0)
	var bar_pos := Vector2(inner.position.x, inner.end.y - bar_h)

	# Tank outline — red when running a deficit (drawing more than it has,
	# but never blocking the consumer — see allow_negative in resource_kinds.gd).
	var frame_col := (UITheme.C_WARN if in_deficit else kind_col)
	if is_ghost:
		frame_col = Color(frame_col.r, frame_col.g, frame_col.b, 0.35)
	draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)), Color(0.10, 0.12, 0.20, 0.92))
	draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)), frame_col, false, 1.2)

	# Bottom-up fill (battery-style)
	var h_fill: float = maxf(1.0, bar_h * level)
	var fill_r := Rect2(bar_pos.x, bar_pos.y + bar_h - h_fill, bar_w, h_fill)
	var c0 := Color(kind_col.r * 0.55, kind_col.g * 0.55, kind_col.b * 0.55, 0.85 if not is_ghost else 0.35)
	var c1 := Color(kind_col.r, kind_col.g, kind_col.b, 0.95 if not is_ghost else 0.40)
	_draw_v_gradient_fill(fill_r, c0, c1)

	var name_ := specs.get("name", ResourceKinds.display_name(kind)) as String
	draw_string(fnt, Vector2(inner.position.x, inner.position.y + fsize),
		name_, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S if not is_ghost else C_TEXT_M)

	var unlimited: bool = bool(specs.get("unlimited_capacity", false))
	var pct_str := "⚠" if in_deficit else ("∞" if unlimited else ("%.0f%%" % (level * 100.0)))
	var pct_col := UITheme.C_WARN if in_deficit else Color(1, 1, 1, 0.92 if not is_ghost else 0.5)
	draw_string(fnt, Vector2(bar_pos.x + bar_w * 0.5 - fsize, bar_pos.y + bar_h * 0.5 + fsize * 0.35),
		pct_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1, pct_col)

	var cap_qty: float = float(specs.get("capacity_qty", 0.0))
	var cap_unit: String = str(specs.get("capacity_unit", ResourceKinds.default_unit(kind)))
	if in_deficit:
		var deficit_str := "Deficit: %.0f %s" % [float(specs.get("deficit_qty", -raw_level * cap_qty)), cap_unit]
		draw_string(fnt, Vector2(inner.position.x, bar_pos.y - 3.0),
			deficit_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, UITheme.C_WARN)
	elif unlimited:
		draw_string(fnt, Vector2(inner.position.x, bar_pos.y - 3.0),
			"No capacity limit", HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)
	elif cap_qty > 0.0:
		var qty_str := "%.0f / %.0f %s" % [level * cap_qty, cap_qty, cap_unit]
		draw_string(fnt, Vector2(inner.position.x, bar_pos.y - 3.0),
			qty_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)

	var infl: float = float(specs.get("inflow_rate", 0.0))
	var outf: float = float(specs.get("outflow_rate", 0.0))
	if infl > 0.01 or outf > 0.01:
		draw_string(fnt, Vector2(inner.end.x - 80.0, inner.position.y + fsize),
			"+%.1f/−%.1f" % [infl, outf], HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 2, C_GREEN)

	_draw_tank_overflow_glyph(specs, Vector2(inner.end.x, bar_pos.y - 3.0))


## Shared ⚠ overflow badge for tank renderers (V1 body + V2 hub).
## Anchor = right-aligned baseline point; zoom-proportional per convention.
func _draw_tank_overflow_glyph(specs: Dictionary, anchor: Vector2) -> void:
	if not bool(specs.get("overflowing", false)):
		return
	var fnt := ThemeDB.fallback_font
	var wf := maxi(8, int(round(11.0 * _zoom)))
	var ts := fnt.get_string_size("⚠", HORIZONTAL_ALIGNMENT_LEFT, -1, wf)
	draw_string(fnt, Vector2(anchor.x - ts.x, anchor.y), "⚠",
		HORIZONTAL_ALIGNMENT_LEFT, -1, wf, UITheme.C_WARN)


func _draw_catchment_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 1, 10.0)
	var x     := rect.position.x + 8.0
	var y     := rect.position.y + fsize + 4.0
	draw_string(fnt, Vector2(x, y), specs.get("name", "Rain Catchment") as String,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	var area_lbl := "%.0f m²" % float(specs.get("area_m2", 10.0))
	if bool(specs.get("use_soi_area", false)):
		area_lbl = "SoI area"
	draw_string(fnt, Vector2(x, y), area_lbl,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 3.0
	if str(specs.get("catchment_kind", "rain")) == "biomass":
		draw_string(fnt, Vector2(x, y), "legacy · use Grow Bed",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)
	else:
		draw_string(fnt, Vector2(x, y), "runoff %.0f%%" % (float(specs.get("runoff_coeff", 0.85)) * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)


func _draw_plant_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 1, 10.0)
	var x := rect.position.x + 8.0
	var y := rect.position.y + fsize + 4.0
	draw_string(fnt, Vector2(x, y), specs.get("name", "Grow Bed") as String,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	var area_lbl := "%.0f m²" % float(specs.get("area_m2", 10.0))
	if bool(specs.get("use_soi_area", false)):
		area_lbl = "SoI area"
	draw_string(fnt, Vector2(x, y), area_lbl,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 3.0
	var rate := float(specs.get("biomass_kg_h", 0.0))
	var rate_col := C_AMBER if rate > 0.0001 else C_TEXT_M
	var rate_str: String
	if rate >= 0.01:
		rate_str = "%.2f kg/h" % rate
	elif rate > 0.0001:
		rate_str = "%.1f g/h" % (rate * 1000.0)
	else:
		rate_str = "0 kg/h"
	draw_string(fnt, Vector2(x, y), rate_str,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, rate_col)
	y += fsize + 2.0
	var sun_f := float(specs.get("sunlight_factor", 1.0))
	if sun_f < 0.995 and y < rect.end.y - 2.0:
		draw_string(fnt, Vector2(x, y), "shade %.0f%%" % (sun_f * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), C_TEXT_M)


# ---------------------------------------------------------------------------
# Port (handle) dots
# ---------------------------------------------------------------------------

## Primary (canonical) handle IDs per type. These always show a port dot even
## when not wired, so the user knows where to grab.  All other handles are only
## shown when they are actually connected to a wire.
const _PRIMARY_HANDLES := {
	"controller":  ["pvPositive", "pvNegative", "batteryPositive", "batteryNegative", "acOutput"],
	"appliance":   ["input"],
	"acload":      ["input"],
	"processor":   ["power_in", "energy_in"],
	"compound":    ["in_ac_1", "in_dc_1", "out_ac_1", "out_dc_1"],
	"shelly4pm":   ["ac_in", "circuit_0", "circuit_1", "circuit_2", "circuit_3"],
	"spiderbox":   ["ac_in", "circuit_0", "circuit_1", "circuit_2", "circuit_3", "circuit_4", "circuit_5"],
	"breaker_panel": ["ac_in", "circuit_0", "circuit_1", "circuit_2", "circuit_3"],
	"panel":       ["positive", "negative", "sunlight_in"],
	"plant":       ["sunlight_in", "water_in", "nutrients_in", "biomass_out"],
	"wind":        ["positive", "negative", "wind_in"],
}

## Build a set of handle IDs that are actually used in at least one connection
## for the given item_id.
func _wired_handle_ids(item_id: String) -> Dictionary:
	var used: Dictionary = {}
	if model == null:
		return used
	for conn: Dictionary in _visible_connections():
		if conn.get("source_item_id", "") == item_id:
			used[conn.get("source_handle_id", "")] = true
		if conn.get("target_item_id", "") == item_id:
			used[conn.get("target_handle_id", "")] = true
	return used


func _draw_item_handles(item: Dictionary, tl: Vector2, sz: Vector2) -> void:
	var itype   := item.get("type", "generic") as String
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var compound_kind := str(specs.get("compound_kind", "")) if itype == "compound" else ""
	var handles := _resolved_handles(item)
	var hub := GraphHubPorts.is_hub_type(itype)

	# Solar arrays expose one consolidated +/- pair on the bottom edge.
	if compound_kind == "array":
		_draw_array_compound_handles(tl, sz)
		return

	# For types that have "extra" symmetry handles, only render a dot for:
	#   a) primary/canonical handles, OR
	#   b) handles that are currently wired to something.
	# This prevents four dots cluttering every load/inverter node.
	var primary: Array = _PRIMARY_HANDLES.get(itype, []) as Array
	var filter_extras: bool = not primary.is_empty()
	var wired: Dictionary  = _wired_handle_ids(item.get("id", "") as String) if filter_extras else {}
	# Hub mode: hide unused static defaults once any hub_* port exists.
	var hub_wired := _wired_handle_ids(item.get("id", "") as String) if hub else {}
	var has_extra_hub := false
	if hub:
		for h0: Dictionary in handles:
			var id0 := str(h0.get("id", ""))
			if id0.begins_with("hub_in_") or id0.begins_with("hub_out_"):
				has_extra_hub = true
				break

	for h: Dictionary in handles:
		var hid := h.get("id", "") as String
		if filter_extras and not primary.has(hid) and not wired.has(hid):
			if not (hid.begins_with("res_in_") or hid.begins_with("res_out_")):
				continue
		# Once hub ports exist, hide unused default input/output dots.
		if hub and has_extra_hub and (hid == "input" or hid == "output") \
				and not hub_wired.has(hid):
			continue
		var pol := h.get("polarity", "positive") as String
		var rk := str(h.get("resource_kind", ""))
		var sp: Vector2
		if hub and h.has("angle_rad"):
			sp = GraphHubPorts.screen_pos_on_circle(tl, sz, float(h.get("angle_rad", 0.0)))
		else:
			var rx  := float(h.get("rx", h.get("x", 0.0) / maxf(1.0, float(item.get("width",  120.0)))))
			var ry  := float(h.get("ry", h.get("y", 0.0) / maxf(1.0, float(item.get("height",  90.0)))))
			var arr_override := _array_compound_handle_override(item, hid)
			if not arr_override.is_empty():
				rx = float(arr_override.get("rx", rx))
				ry = float(arr_override.get("ry", ry))
			sp  = tl + Vector2(sz.x * rx, sz.y * ry)
		_draw_port_dot(sp, pol, rk)


func _draw_array_compound_handles(tl: Vector2, sz: Vector2) -> void:
	for port: Dictionary in GraphArrayLayout.default_handles():
		var rx := float(port.get("rx", 0.5))
		var ry := float(port.get("ry", 1.0))
		var sp := tl + Vector2(sz.x * rx, sz.y * ry)
		_draw_port_dot(sp, str(port.get("polarity", "positive")))


func _draw_port_dot(screen_pos: Vector2, polarity: String, resource_kind: String = "") -> void:
	var touch := _touch_input_active() or DisplayServer.is_touchscreen_available()
	var r   := maxf(5.0, 6.0 * _zoom)
	if touch:
		r = maxf(r, 9.0)
	var col := _wire_color_for_port(polarity, resource_kind)
	draw_circle(screen_pos, r + (3.5 if touch else 1.5), Color(col.r, col.g, col.b, 0.35))
	draw_circle(screen_pos, r,       col)
	draw_circle(screen_pos, r * 0.45, C_CANVAS_BG)
	draw_circle(screen_pos, r, Color(col.r * 1.15, col.g * 1.15, col.b * 1.15, 0.9), false)
	if touch:
		draw_circle(screen_pos, r + 6.0, Color(col.r, col.g, col.b, 0.12), false, 1.5)


# ---------------------------------------------------------------------------
# Fallback 3-node overlay (when model is empty)
# ---------------------------------------------------------------------------



# ---------------------------------------------------------------------------
# Dot grid
# ---------------------------------------------------------------------------

func _draw_dot_grid() -> void:
	# Floor the on-screen spacing: at low zoom `40*_zoom` shrinks toward a few
	# pixels, turning this into tens of thousands of draw_circle calls across the
	# viewport (quadratic in 1/zoom). The grid is decorative, so cap the density.
	var step  := maxf(40.0 * _zoom, 26.0)
	var off   := Vector2(fposmod(_pan.x, step), fposmod(_pan.y, step))
	var dot_c := Color(0.133, 0.827, 0.933, 0.07 * canvas_bg_alpha)
	var hole_r2 := 0.0
	var hole_o := Vector2.ZERO
	if soi_live_preview:
		var soi_svc := _cached_autoload("/root/SoiService")
		var r_m := 150.0
		if soi_svc != null and soi_svc.has_method("radius_m"):
			r_m = float(soi_svc.call("radius_m"))
		var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
		hole_r2 = r_px * r_px
		hole_o = size * 0.5 + _pan
	var x     := off.x
	while x < size.x:
		var y := off.y
		while y < size.y:
			if hole_r2 <= 0.0 or Vector2(x, y).distance_squared_to(hole_o) > hole_r2:
				draw_circle(Vector2(x, y), 1.0, dot_c)
			y += step
		x += step


## Opaque canvas fill everywhere except the SoI disc (live SubViewport shows).
func _draw_canvas_fill_with_soi_hole(fill: Color) -> void:
	var soi_svc := _cached_autoload("/root/SoiService")
	var r_m := 150.0
	if soi_svc != null and soi_svc.has_method("radius_m"):
		r_m = float(soi_svc.call("radius_m"))
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	var origin := size * 0.5 + _pan
	var left := origin.x - r_px
	var right := origin.x + r_px
	var top := origin.y - r_px
	var bottom := origin.y + r_px
	# Four rectangles around the bounding square of the disc.
	if top > 0.0:
		draw_rect(Rect2(0.0, 0.0, size.x, clampf(top, 0.0, size.y)), fill)
	if bottom < size.y:
		draw_rect(Rect2(0.0, maxf(bottom, 0.0), size.x, size.y - maxf(bottom, 0.0)), fill)
	var mid_top := clampf(top, 0.0, size.y)
	var mid_h := clampf(bottom, 0.0, size.y) - mid_top
	if mid_h > 0.0:
		if left > 0.0:
			draw_rect(Rect2(0.0, mid_top, clampf(left, 0.0, size.x), mid_h), fill)
		if right < size.x:
			draw_rect(Rect2(maxf(right, 0.0), mid_top, size.x - maxf(right, 0.0), mid_h), fill)
	# Square corners outside the circle (four quadrant fans).
	var segs := 10
	var corners := [
		Vector2(origin.x + r_px, origin.y - r_px), # NE, arc -PI/2 → 0
		Vector2(origin.x + r_px, origin.y + r_px), # SE, arc 0 → PI/2
		Vector2(origin.x - r_px, origin.y + r_px), # SW, arc PI/2 → PI
		Vector2(origin.x - r_px, origin.y - r_px), # NW, arc PI → 3PI/2
	]
	var a0s := [-PI * 0.5, 0.0, PI * 0.5, PI]
	for q in range(4):
		var corner: Vector2 = corners[q]
		var a0: float = a0s[q]
		for i in range(segs):
			var t0 := a0 + (PI * 0.5) * (float(i) / float(segs))
			var t1 := a0 + (PI * 0.5) * (float(i + 1) / float(segs))
			var p0 := origin + Vector2(cos(t0), sin(t0)) * r_px
			var p1 := origin + Vector2(cos(t1), sin(t1)) * r_px
			draw_colored_polygon(PackedVector2Array([corner, p0, p1]), fill)


func _draw_soi_background() -> void:
	var soi_svc := _cached_autoload("/root/SoiService")
	var r_m := 150.0
	if soi_svc != null and soi_svc.has_method("radius_m"):
		r_m = soi_svc.radius_m()
	
	# Mapping radius in meters to graph coordinates (keep in sync with
	# GraphSiteLayout.SOI_PX_PER_M).
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	var origin := size * 0.5 + _pan

	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		_draw_elevation_section(origin, r_px, r_m, soi_svc)
		return
	
	# When live SoI preview is on, leave the disc clear so the SubViewport
	# shows through; keep a thin ring as a graph-coordinate reference.
	if soi_live_preview:
		var ring_col := Color(0.2, 0.75, 1.0, 0.55)
		draw_arc(origin, r_px, 0.0, TAU, 96, ring_col, maxf(2.0, 2.5 * _zoom), true)
		draw_line(Vector2(origin.x - r_px, origin.y), Vector2(origin.x + r_px, origin.y),
				Color(1.0, 1.0, 1.0, 0.12), 1.0)
		return

	var ring_col2 := Color(0.2, 0.6, 0.9, 0.15)
	draw_circle(origin, r_px, Color(0.05, 0.1, 0.15, 0.2))
	draw_arc(origin, r_px, 0.0, TAU, 64, ring_col2, 4.0 * _zoom, true)
	
	# Decorative elevation slice (freeform only) — real profile is elevation view.
	var line_pts := PackedVector2Array()
	var segments := 32
	var width_px := r_px * 2.0
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var lx := origin.x - r_px + width_px * t
		var elev_offset := sin(t * PI * 3.0) * 20.0 * _zoom + cos(t * PI * 7.0) * 10.0 * _zoom
		line_pts.append(Vector2(lx, origin.y - elev_offset))
	
	if line_pts.size() > 1:
		_draw_polyline_stroke(line_pts, Color(0.4, 0.8, 0.5, 0.3), 2.0 * _zoom)
		draw_line(Vector2(origin.x - r_px, origin.y), Vector2(origin.x + r_px, origin.y), Color(1.0, 1.0, 1.0, 0.1), 1.0)


func _draw_elevation_section(origin: Vector2, r_px: float, r_m: float, soi_svc: Node) -> void:
	# Contained in the SoI disc. When the 3D section backdrop is live, leave the
	# fill clear so sky / buildings show through; keep ring + terrain profile.
	if not soi_live_preview:
		draw_circle(origin, r_px, Color(0.04, 0.07, 0.12, 0.82))
	var ring_col := Color(0.2, 0.75, 1.0, 0.55)
	draw_arc(origin, r_px, 0.0, TAU, 96, ring_col, maxf(2.0, 2.5 * _zoom), true)

	var heading_deg := rad_to_deg(elevation_heading_rad)
	var fnt := ThemeDB.fallback_font
	var mode_tag := " · 3D" if soi_live_preview else ""
	# Label just above the disc so it isn't clipped oddly near the rim.
	draw_string(fnt, origin + Vector2(-r_px + 6.0, -r_px - 6.0),
			"Elevation · heading %.0f° · %d× vert%s  (Shift+drag rotate)" % [
				heading_deg, int(elevation_exaggeration), mode_tag],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.65, 0.85, 1.0, 0.85))

	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var datum := center3.y
	var s := GraphSiteLayout.px_per_m(_zoom)
	var samples := 128
	var line_pts := PackedVector2Array()
	var along_dir := Vector2(cos(elevation_heading_rad), sin(elevation_heading_rad))
	for i in range(samples + 1):
		var t := float(i) / float(samples)
		var along := lerpf(-r_m, r_m, t)
		var site := along_dir * along
		var world := GraphSiteLayout.site_to_world_xz(site, center3)
		var gy := datum
		if soi_svc != null and soi_svc.has_method("ground_y_at"):
			gy = float(soi_svc.call("ground_y_at", world.x, world.y))
		var sx := origin.x + along * s
		var sy := origin.y - (gy - datum) * s * elevation_exaggeration
		# Keep the profile inside the disc (soft radial clamp to rim chord).
		var dx := sx - origin.x
		var max_dy := sqrt(maxf(r_px * r_px - dx * dx, 0.0))
		sy = clampf(sy, origin.y - max_dy, origin.y + max_dy)
		line_pts.append(Vector2(sx, sy))

	# Horizontal datum chord across the disc.
	draw_line(Vector2(origin.x - r_px, origin.y), Vector2(origin.x + r_px, origin.y),
			Color(1.0, 1.0, 1.0, 0.18), 1.0)

	if line_pts.size() > 1:
		if not soi_live_preview:
			# Fill under the profile, closed along the lower disc rim.
			var fill := PackedVector2Array()
			for p in line_pts:
				fill.append(p)
			# Walk the lower semicircle from right → left.
			var rim_segs := 48
			for i in range(rim_segs + 1):
				var a := lerpf(0.0, PI, float(i) / float(rim_segs))
				fill.append(origin + Vector2(cos(a), sin(a)) * r_px)
			if fill.size() >= 3:
				draw_colored_polygon(fill, Color(0.18, 0.42, 0.28, 0.55))
		_draw_polyline_stroke(line_pts, Color(0.45, 0.95, 0.65, 0.95), maxf(2.0, 2.5 * _zoom))



# ---------------------------------------------------------------------------
# Metro Style Routing
# ---------------------------------------------------------------------------

func _draw_wire_metro_path(pts: Array, tangents: Array, col: Color, width: float, flowing: bool, rate: float, reverse: bool, conn: Dictionary) -> void:
	# Metro path consists of rectilinear segments and 45-degree chamfers.
	var draw_pts := PackedVector2Array()
	var src_p := pts[0] as Vector2
	var tgt_p := pts[-1] as Vector2
	
	if pts.size() == 2:
		# Auto-route honoring the actual port sides (tangents), so a metro track
		# exits/enters along the port stub instead of always assuming top/bottom
		# ports. src tangent points outward from the source port; tgt tangent is
		# the incoming travel direction at the target port.
		var src_t := Vector2(0.0, 1.0)
		var tgt_t_in := Vector2(0.0, 1.0)
		if tangents.size() > 0:
			src_t = tangents[0] as Vector2
		if tangents.size() > 1:
			tgt_t_in = tangents[1] as Vector2
		var src_horiz := absf(src_t.x) >= absf(src_t.y)
		var tgt_horiz := absf(tgt_t_in.x) >= absf(tgt_t_in.y)
		var mid_x := (src_p.x + tgt_p.x) * 0.5
		var mid_y := (src_p.y + tgt_p.y) * 0.5
		draw_pts.append(src_p)
		if src_horiz and tgt_horiz:
			# Both ports face sideways: Z with the cross-leg vertical at mid_x.
			draw_pts.append(Vector2(mid_x, src_p.y))
			draw_pts.append(Vector2(mid_x, tgt_p.y))
		elif not src_horiz and not tgt_horiz:
			# Both ports face up/down: Z with the cross-leg horizontal at mid_y.
			draw_pts.append(Vector2(src_p.x, mid_y))
			draw_pts.append(Vector2(tgt_p.x, mid_y))
		elif src_horiz:
			# L-route: horizontal stub out, then drop vertically into the target.
			draw_pts.append(Vector2(tgt_p.x, src_p.y))
		else:
			# L-route: vertical stub out, then across horizontally into the target.
			draw_pts.append(Vector2(src_p.x, tgt_p.y))
		draw_pts.append(tgt_p)
	else:
		for p in pts:
			draw_pts.append(p as Vector2)
	
	# Apply 45-degree corner break (chamfering) using corner radius
	var r := float(conn.get("corner_radius", 28.0)) * _zoom
	var final_pts := PackedVector2Array()
	if draw_pts.size() >= 2:
		final_pts.append(draw_pts[0])
		for i in range(1, draw_pts.size() - 1):
			var prev := draw_pts[i-1]
			var cur := draw_pts[i]
			var nxt := draw_pts[i+1]
			var v1 := prev - cur
			var v2 := nxt - cur
			var len1 := v1.length()
			var len2 := v2.length()
			if len1 > 0.001 and len2 > 0.001:
				var limit := minf(len1 * 0.5, len2 * 0.5)
				var d := minf(r, limit)
				if d > 0.001:
					var c1 := cur + v1.normalized() * d
					var c2 := cur + v2.normalized() * d
					final_pts.append(c1)
					final_pts.append(c2)
				else:
					final_pts.append(cur)
			else:
				final_pts.append(cur)
		final_pts.append(draw_pts[-1])
	else:
		final_pts = draw_pts
	
	# Draw the thick track
	var track_col := Color(col.r, col.g, col.b, 0.8)
	var base_w := 15.0 * _zoom
	var c_thick = float(conn.get("thickness_override", 0.0))
	if c_thick > 0.1:
		base_w = c_thick * _zoom
	var track_w := base_w
	
	# Apply Sankey scaling if configured
	if bool(conn.get("sankey_scale", true)):
		# Scale width based on flow rate, assuming `base_w` is a base/default
		var sankey_factor := clampf(rate / 500.0, 0.5, 4.0)
		track_w = base_w * sankey_factor

	# Draw segments
	for i in range(final_pts.size() - 1):
		var p1 := final_pts[i]
		var p2 := final_pts[i+1]
		draw_line(p1, p2, track_col, track_w)
		draw_circle(p2, track_w * 0.5, track_col)
	
	if final_pts.size() > 0:
		draw_circle(final_pts[0], track_w * 0.5, track_col)
	
	# Flow animation
	if flowing:
		var c2 := Color(1.0, 1.0, 1.0, 0.6)
		_draw_polyline_chase(final_pts, c2, maxf(2.0, track_w * 0.3), rate, reverse)
	
	# Draw stations (waypoints)
	if pts.size() > 2:
		for i in range(1, pts.size() - 1):
			var wp := pts[i] as Vector2
			draw_circle(wp, track_w * 0.8, Color.WHITE)
			draw_circle(wp, track_w * 0.5, track_col)


# ---------------------------------------------------------------------------
# Coordinate helpers
# ---------------------------------------------------------------------------

func _disc_origin_screen() -> Vector2:
	return size * 0.5 + _pan


func _is_physical_view() -> bool:
	return view_mode == GraphSiteLayout.VIEW_SITE \
			or view_mode == GraphSiteLayout.VIEW_ELEVATION


func _item_screen_tl(item: Dictionary, center: Vector2) -> Vector2:
	if view_mode == GraphSiteLayout.VIEW_SITE and GraphSiteLayout.has_site_coords(item):
		return GraphSiteLayout.site_item_screen_tl(item, _disc_origin_screen(), _zoom)
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and GraphSiteLayout.has_site_coords(item):
		return _elevation_item_screen_tl(item)
	if view_mode != GraphSiteLayout.VIEW_FREEFORM and not GraphSiteLayout.has_site_coords(item):
		# Unplaced items sit in the tray (handled by _unplaced_tray_rect).
		var idx := _unplaced_index(item)
		if idx >= 0:
			return _unplaced_slot_tl(idx)
	return center + _pan + Vector2(float(item.get("x", 0.0)),
		float(item.get("y", 0.0))) * _zoom


func _item_screen_size(item: Dictionary) -> Vector2:
	if view_mode == GraphSiteLayout.VIEW_SITE and GraphSiteLayout.has_site_coords(item):
		return GraphSiteLayout.site_item_screen_size(item, _zoom)
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and GraphSiteLayout.has_site_coords(item):
		var fp := GraphSiteLayout.physical_footprint_m(item)
		var s := GraphSiteLayout.px_per_m(_zoom)
		# Depth along the section for width; height from a short elevation band.
		return Vector2(maxf(maxf(fp.x, fp.y) * s, 0.5), maxf(maxf(fp.y, 1.0) * s * 0.35, 0.5))
	if view_mode != GraphSiteLayout.VIEW_FREEFORM and not GraphSiteLayout.has_site_coords(item):
		# Tray chips: scale with zoom like the rest of the map (no inverse floor).
		return Vector2(72.0, 36.0) * maxf(_zoom, 0.15)
	return Vector2(float(item.get("width", 120.0)),
		float(item.get("height", 90.0))) * _zoom


## Hit/pick rect — physical views enlarge tiny footprints for usability.
func _item_hit_rect(item: Dictionary) -> Rect2:
	var center := size * 0.5
	if view_mode == GraphSiteLayout.VIEW_SITE and GraphSiteLayout.has_site_coords(item):
		return GraphSiteLayout.site_item_hit_rect(item, _disc_origin_screen(), _zoom)
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and GraphSiteLayout.has_site_coords(item):
		var tl := _elevation_item_screen_tl(item)
		var draw_sz := _item_screen_size(item)
		var hit_sz := Vector2(
			maxf(draw_sz.x, GraphSiteLayout.MIN_SITE_HIT_PX),
			maxf(draw_sz.y, GraphSiteLayout.MIN_SITE_HIT_PX * 0.55))
		var c := tl + draw_sz * 0.5
		return Rect2(c - hit_sz * 0.5, hit_sz)
	var tl2 := _item_screen_tl(item, center)
	var sz2 := _item_screen_size(item)
	return Rect2(tl2, sz2)


func _elevation_item_screen_tl(item: Dictionary) -> Vector2:
	var origin := _disc_origin_screen()
	var s := GraphSiteLayout.px_per_m(_zoom)
	var site := GraphSiteLayout.site_xz(item)
	var proj := GraphSiteLayout.project_onto_section(site, elevation_heading_rad)
	var elev_m := _elevation_m_for_item(item)
	var datum := _elevation_datum_m()
	var sz := _item_screen_size(item)
	var cx := origin.x + proj.x * s
	var cy := origin.y - (elev_m - datum) * s * elevation_exaggeration
	return Vector2(cx, cy) - sz * 0.5


func _elevation_datum_m() -> float:
	var soi := _cached_autoload("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		return float((soi.call("world_center") as Vector3).y)
	return 0.0


func _elevation_m_for_item(item: Dictionary) -> float:
	if item.has("elevation_m"):
		return float(item.get("elevation_m", 0.0))
	# Fall back to SoI center Y until refreshed by the view.
	return _elevation_datum_m()


func _unplaced_items() -> Array:
	var out: Array = []
	if not _is_physical_view() or model == null:
		return out
	for item: Dictionary in _visible_items():
		if not GraphSiteLayout.has_site_coords(item):
			out.append(item)
	return out


func _unplaced_index(item: Dictionary) -> int:
	var iid := str(item.get("id", ""))
	var list := _unplaced_items()
	for i in list.size():
		if str((list[i] as Dictionary).get("id", "")) == iid:
			return i
	return -1


func _unplaced_tray_rect() -> Rect2:
	var h := 48.0
	return Rect2(8.0, size.y - h - 8.0, maxf(size.x - 16.0, 40.0), h)


func _unplaced_slot_tl(idx: int) -> Vector2:
	var tray := _unplaced_tray_rect()
	return Vector2(tray.position.x + 8.0 + float(idx) * 80.0, tray.position.y + 6.0)


func _draw_unplaced_tray() -> void:
	if not _is_physical_view():
		return
	var list := _unplaced_items()
	var tray := _unplaced_tray_rect()
	draw_rect(tray, Color(0.06, 0.09, 0.16, 0.92), true)
	draw_rect(tray, Color(0.25, 0.55, 0.85, 0.55), false, 1.5)
	var fnt := ThemeDB.fallback_font
	var label := "Unplaced (%d) — drop onto SoI disc" % list.size()
	draw_string(fnt, tray.position + Vector2(10.0, -4.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.85, 1.0, 0.85))
	# Soft glow on the SoI disc when items wait to be placed.
	if list.size() > 0:
		var disc := get_soi_disc_layout()
		var origin: Vector2 = disc.get("origin", Vector2.ZERO)
		var r_px: float = float(disc.get("radius_px", 0.0))
		if r_px > 8.0:
			draw_arc(origin, r_px, 0.0, TAU, 64,
					Color(0.3, 0.7, 1.0, 0.28), 2.0, true)


## Graph-space disc matching `_draw_soi_background` (origin + radius_px).
func get_soi_disc_layout() -> Dictionary:
	var soi_svc := _cached_autoload("/root/SoiService")
	var r_m := 150.0
	if soi_svc != null and soi_svc.has_method("radius_m"):
		r_m = float(soi_svc.call("radius_m"))
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	return {
		"origin": size * 0.5 + _pan,
		"radius_px": r_px,
		"radius_m": r_m,
	}


func _draw_site_plan_chip(item: Dictionary, rect: Rect2, is_sel: bool) -> void:
	var itype := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var border := NODE_BORDER_COLORS.get(itype, C_BORDER) as Color
	if is_sel:
		border = C_SELECTED_BORDER
	# OSM imports: amber roof / green field highlight matching world outlines.
	if not str(specs.get("osm_tag", "")).is_empty():
		if itype == "catchment":
			border = Color(1.0, 0.72, 0.18, 1.0) if not is_sel else C_SELECTED_BORDER
		elif itype == "plant":
			border = Color(0.35, 0.85, 0.42, 1.0) if not is_sel else C_SELECTED_BORDER
	var fill := Color(0.09, 0.14, 0.22, 0.92)
	var min_side := minf(rect.size.x, rect.size.y)
	# Stroke scales with footprint so a 2 px panel isn't buried under a 4 px border.
	var stroke := clampf(min_side * 0.12, 0.75, maxf(1.25, 2.0 * _zoom))
	var c := rect.get_center()
	# True physical outline (1 px) when chip is scaled up beyond footprint.
	_draw_true_footprint_outline(item, c, border)
	# OSM polygon outline chip when local site-poly exists.
	if _draw_osm_site_poly(item, c, border, is_sel):
		var title_osm := _site_plan_chip_title(item, specs, itype)
		_draw_site_plan_chip_label(rect, title_osm, is_sel)
		return
	# Locator ring when the true footprint is smaller than the pick pad — shows
	# where to click without inflating the filled area away from the map.
	if GraphSiteLayout.has_site_coords(item) and min_side < GraphSiteLayout.MIN_SITE_HIT_PX * 0.85:
		var loc_r := GraphSiteLayout.MIN_SITE_HIT_PX * 0.5
		var loc_a := 0.55 if is_sel else 0.28
		draw_arc(c, loc_r, 0.0, TAU, 28,
				Color(border.r, border.g, border.b, loc_a), 1.0, true)
	if GraphSiteLayout.uses_circular_plan_chip(item):
		var r := maxf(min_side * 0.5, 0.5)
		draw_circle(c, r, fill)
		draw_arc(c, r, 0.0, TAU, 32, border, stroke, true)
	else:
		draw_rect(rect, fill, true)
		draw_rect(rect, border, false, stroke)
		# Solar-array packs: light module grid so the footprint reads as panels.
		if itype == "compound" \
				and str(specs.get("compound_kind", "")) == "array" \
				and rect.size.x >= 10.0 and rect.size.y >= 8.0:
			_draw_site_array_grid(rect, specs, border)
	var title := _site_plan_chip_title(item, specs, itype)
	_draw_site_plan_chip_label(rect, title, is_sel)


## Translucent outline at physical size when map_display_scale / min chip inflate.
func _draw_true_footprint_outline(item: Dictionary, center: Vector2, border: Color) -> void:
	if not GraphSiteLayout.has_site_coords(item):
		return
	var true_sz := GraphSiteLayout.true_footprint_screen_size(item, _zoom)
	var chip_sz := GraphSiteLayout.site_item_screen_size(item, _zoom)
	if true_sz.x >= chip_sz.x * 0.92 and true_sz.y >= chip_sz.y * 0.92:
		return
	var true_rect := Rect2(center - true_sz * 0.5, true_sz)
	var col := Color(border.r, border.g, border.b, 0.45 if true_sz.x >= 4.0 else 0.3)
	if GraphSiteLayout.uses_circular_plan_chip(item):
		var r := maxf(minf(true_sz.x, true_sz.y) * 0.5, 0.5)
		draw_arc(center, r, 0.0, TAU, 28, col, 1.0, true)
	else:
		draw_rect(true_rect, col, false, 1.0)


## Draw OSM polygon (site-relative metres) as outline chip; returns true if drawn.
func _draw_osm_site_poly(item: Dictionary, center: Vector2, border: Color, is_sel: bool) -> bool:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var poly_v: Variant = specs.get("osm_poly_site", null)
	if not (poly_v is PackedVector2Array) and not (poly_v is Array):
		return false
	var pts := PackedVector2Array()
	if poly_v is PackedVector2Array:
		pts = poly_v as PackedVector2Array
	else:
		for p in poly_v as Array:
			if p is Vector2:
				pts.append(p as Vector2)
			elif p is Array and (p as Array).size() >= 2:
				pts.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
	if pts.size() < 3:
		return false
	var s := GraphSiteLayout.px_per_m(_zoom)
	var screen := PackedVector2Array()
	screen.resize(pts.size())
	for i in pts.size():
		screen[i] = center + pts[i] * s
	var fill := Color(border.r, border.g, border.b, 0.22 if is_sel else 0.14)
	draw_colored_polygon(screen, fill)
	for i in screen.size():
		var a := screen[i]
		var b := screen[(i + 1) % screen.size()]
		draw_line(a, b, border, 1.5 if is_sel else 1.0, true)
	return true


## Title inside (or floating beside) a site-plan footprint — sized from the chip
## metres×zoom; no fixed screen-px floor that fights the map when zooming.
func _draw_site_plan_chip_label(rect: Rect2, title: String, is_sel: bool) -> void:
	if title.is_empty():
		return
	var fnt := ThemeDB.fallback_font
	var min_side := minf(rect.size.x, rect.size.y)
	var c := rect.get_center()
	# Design ~11 graph-px × zoom, capped so it stays inside the footprint.
	var ideal := minf(11.0 * _zoom, min_side * 0.30)
	ideal = minf(ideal, rect.size.x * 0.14)
	var fsize := clampi(int(round(ideal)), 1, 36)
	var pad := maxf(1.0, 3.0 * _zoom)
	if fsize >= 5 and rect.size.x >= float(fsize) * 2.5:
		var shown := GraphNodeLabel.ellipsis(fnt, title, maxf(rect.size.x - pad * 2.0, 4.0), fsize)
		var ts := fnt.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
		# Centered in the chip so it stays locked when zooming.
		draw_string(fnt, Vector2(c.x - ts.x * 0.5, c.y + float(fsize) * 0.35),
				shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.9, 0.95, 1.0, 0.95))
		return
	# Too small to fit inside — selected only: callout scaled with zoom.
	if not is_sel:
		return
	var call_ideal := maxf(8.0 * _zoom, ideal * 1.4)
	if call_ideal < 5.0:
		return
	var call_fs := clampi(int(round(call_ideal)), 5, 14)
	var z := maxf(_zoom, 0.05)
	var call_off := Vector2(
		maxf(rect.size.x * 0.5, 6.0 * z) + 4.0 * z,
		-6.0 * z)
	draw_string(fnt, c + call_off, title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, call_fs, Color(0.95, 0.98, 1.0, 0.95))


func _site_plan_chip_title(item: Dictionary, specs: Dictionary, itype: String) -> String:
	if itype == "compound" and str(specs.get("compound_kind", "")) == "array":
		var n := int(specs.get("array_panel_units", specs.get("child_count", 0)))
		if n > 0:
			return "Array · %d" % n
		return "Solar Array"
	return str(specs.get("name", itype.capitalize()))


func _draw_site_array_grid(rect: Rect2, specs: Dictionary, accent: Color) -> void:
	var grid: Vector2i = GraphArrayLayout.grid_dims(specs)
	var cols := maxi(grid.x, 1)
	var rows := maxi(grid.y, 1)
	var pad := maxf(1.0, minf(rect.size.x, rect.size.y) * 0.06)
	var gap := maxf(0.5, pad * 0.35)
	var cell_w := (rect.size.x - pad * 2.0 - gap * float(maxi(cols - 1, 0))) / float(cols)
	var cell_h := (rect.size.y - pad * 2.0 - gap * float(maxi(rows - 1, 0))) / float(rows)
	if cell_w < 2.0 or cell_h < 2.0:
		return
	var origin := rect.position + Vector2(pad, pad)
	for r in range(rows):
		for c in range(cols):
			var cell := Rect2(
				origin + Vector2(float(c) * (cell_w + gap), float(r) * (cell_h + gap)),
				Vector2(cell_w, cell_h))
			draw_rect(cell, Color(0.05, 0.16, 0.28, 0.85), true)
			draw_rect(cell, Color(accent.r, accent.g, accent.b, 0.45), false, 0.8)


func _type_title(itype: String, specs: Dictionary) -> String:
	match itype:
		"panel":        return "SOLAR ARRAY"
		"wind":         return "WIND TURBINE"
		"hydro":        return "HYDRO TURBINE"
		"battery":      return "BATTERY"
		"smartbattery": return "SMART BATTERY"
		"controller":   return "CONTROLLER"
		"appliance", "acload": return "LOAD"
		"shelly4pm":    return "SHELLY PRO 4PM"
		"spiderbox":    return "SPIDERBOX"
		"breaker_panel": return "BREAKER PANEL"
		"breaker":      return "BREAKER"
		"combiner":     return "COMBINER"
		"solarcombiner":return "SOLAR COMBINER"
		"acbreaker":    return "AC BREAKER"
		"acoutlet":     return "AC OUTLET"
		"processor":    return "PROCESSOR"
		"resource":     return "RESOURCE"
		"catchment":    return "CATCHMENT"
		"plant":        return "GROW BED"
		"compound":     return "COMPOUND"
	return itype.to_upper()


## Returns default width for a type.
static func default_width(itype: String) -> float:
	if NodeSizes.has(itype):
		return float(NodeSizes[itype][0])
	return float(NODE_SIZE_DEFAULT[0])


## Returns default height for a type.
static func default_height(itype: String) -> float:
	if NodeSizes.has(itype):
		return float(NodeSizes[itype][1])
	return float(NODE_SIZE_DEFAULT[1])


# Workaround: reference NODE_SIZES via a renamed alias so static funcs can use it
const NodeSizes := NODE_SIZES

func _draw_pbi_body(rect: Rect2, specs: Dictionary, _item: Dictionary) -> void:
	var kind: String = str(specs.get("resource_kind", ""))
	var is_active: bool = bool(specs.get("is_active", false))
	var pbi_val: String = str(specs.get("display_value", ""))
	var center: Vector2 = rect.position + rect.size * 0.5
	var r: float = minf(rect.size.x, rect.size.y) * 0.5
	var title := str(specs.get("name", kind.capitalize()))

	if kind == "solar" or kind == "sunlight" or kind == "thermal":
		_draw_sun_pbi_body(center, r, is_active, title, pbi_val)
		return
	if kind == "wind" or kind == "mechanical" or kind == "atmosphere" or kind == "air":
		_draw_wind_pbi_body(center, r, is_active, specs, title, pbi_val)
		return
	if kind == "water" or kind == "rain":
		_draw_rain_pbi_body(center, r, is_active, title, pbi_val)
		return

	var col := Color(0.45, 0.55, 0.5)
	if is_active:
		var glow_r = r + (10.0 * _zoom) * (0.8 + 0.2 * sin(_flow_phase * TAU * 2.0))
		draw_circle(center, glow_r, Color(col.r, col.g, col.b, 0.3))
	draw_circle(center, r, col)
	draw_arc(center, r, 0, TAU, 32, Color(1, 1, 1, 0.2), 2.0 * _zoom)
	_draw_pbi_labels(center, r * 0.85, title, pbi_val, Color.WHITE, Color(1, 1, 1, 0.9))


## Bold, oversized PBI title + value with dark outline for contrast on icons.
func _draw_pbi_labels(center: Vector2, max_w: float, title: String, value: String,
		title_col: Color, value_col: Color) -> void:
	var fnt := ThemeDB.fallback_font
	var fsize_title: int = maxi(12, int(round(max_w * 0.38 / maxf(_zoom, 0.01))))
	var fsize_val: int = maxi(10, int(round(max_w * 0.26 / maxf(_zoom, 0.01))))
	while fsize_title > 9:
		var tw := fnt.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize_title).x
		if tw <= max_w * 1.85:
			break
		fsize_title -= 1
	while fsize_val > 8 and not value.is_empty():
		var vw := fnt.get_string_size(value, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize_val).x
		if vw <= max_w * 1.95:
			break
		fsize_val -= 1
	var outline := Color(0.0, 0.0, 0.0, 0.72)
	var title_y: float = -4.0 * _zoom if value.is_empty() else -max_w * 0.22
	_draw_outlined_string(fnt, center + Vector2(0.0, title_y), title, fsize_title, title_col, outline)
	if not value.is_empty():
		_draw_outlined_string(fnt, center + Vector2(0.0, max_w * 0.32), value, fsize_val, value_col, outline)


func _draw_outlined_string(fnt: Font, center_baseline: Vector2, text: String,
		fsize: int, fill: Color, outline: Color) -> void:
	var ts := fnt.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
	var origin := center_baseline - Vector2(ts.x * 0.5, 0.0)
	var o := maxf(1.0, 1.4 * _zoom)
	for d: Vector2 in [
		Vector2(-o, 0), Vector2(o, 0), Vector2(0, -o), Vector2(0, o),
		Vector2(-o, -o), Vector2(o, -o), Vector2(-o, o), Vector2(o, o),
	]:
		draw_string(fnt, origin + d, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, outline)
	draw_string(fnt, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, fill)


## Weather-forecast sun: bright disc + triangular rays (pulse when active).
func _draw_sun_pbi_body(center: Vector2, outer_r: float, is_active: bool,
		title: String, pbi_val: String) -> void:
	var gold := Color(1.0, 0.82, 0.18)
	var amber := Color(1.0, 0.55, 0.08)
	var core := Color(1.0, 0.96, 0.55)
	var pulse: float = 1.0
	if is_active:
		pulse = 0.92 + 0.08 * sin(_flow_phase * TAU * 1.6)
	var halo_r: float = outer_r * (1.18 + 0.06 * pulse)
	draw_circle(center, halo_r, Color(gold.r, gold.g, gold.b, 0.18 if is_active else 0.08))
	if is_active:
		draw_circle(center, outer_r * (1.08 + 0.04 * pulse), Color(1.0, 0.9, 0.35, 0.22))
	var disc_r: float = outer_r * 0.48
	var ray_inner: float = disc_r * 1.08
	var ray_outer: float = outer_r * (0.96 + 0.04 * pulse)
	var ray_count := 12
	var half_w: float = TAU / float(ray_count) * 0.28
	var rot: float = _flow_phase * TAU * 0.04 if is_active else 0.0
	for i in ray_count:
		var a: float = rot + float(i) * TAU / float(ray_count)
		var tip := center + Vector2(cos(a), sin(a)) * ray_outer
		var b0 := center + Vector2(cos(a - half_w), sin(a - half_w)) * ray_inner
		var b1 := center + Vector2(cos(a + half_w), sin(a + half_w)) * ray_inner
		var ray_col := Color(gold.r, gold.g, gold.b, 0.95 if is_active else 0.55)
		if i % 2 == 1:
			ray_col = Color(amber.r, amber.g, amber.b, ray_col.a)
		draw_colored_polygon(PackedVector2Array([tip, b0, b1]), ray_col)
		draw_line(b0, tip, Color(1.0, 0.95, 0.6, 0.55), maxf(0.8, 1.1 * _zoom))
		draw_line(b1, tip, Color(1.0, 0.95, 0.6, 0.55), maxf(0.8, 1.1 * _zoom))
	draw_circle(center, disc_r, amber)
	draw_circle(center, disc_r * 0.88, gold)
	draw_circle(center, disc_r * 0.55, core)
	draw_arc(center, disc_r, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.35), maxf(1.2, 2.0 * _zoom))
	_draw_pbi_labels(center, disc_r * 0.95, title, pbi_val,
			Color(0.18, 0.08, 0.02, 1.0), Color(0.22, 0.10, 0.03, 0.95))


## Rain PBI: blue disc with droplet silhouette.
func _draw_rain_pbi_body(center: Vector2, outer_r: float, is_active: bool,
		title: String, pbi_val: String) -> void:
	var deep := Color(0.12, 0.35, 0.72)
	var mid := Color(0.22, 0.55, 0.92)
	var lite := Color(0.55, 0.82, 1.0)
	if is_active:
		var glow_r = outer_r * (1.12 + 0.05 * sin(_flow_phase * TAU * 2.0))
		draw_circle(center, glow_r, Color(mid.r, mid.g, mid.b, 0.28))
	draw_circle(center, outer_r * 0.92, deep)
	draw_circle(center, outer_r * 0.78, mid)
	var tip := center + Vector2(0.0, -outer_r * 0.42)
	var left := center + Vector2(-outer_r * 0.28, outer_r * 0.08)
	var right := center + Vector2(outer_r * 0.28, outer_r * 0.08)
	var bot := center + Vector2(0.0, outer_r * 0.38)
	draw_colored_polygon(PackedVector2Array([tip, left, bot, right]), lite)
	draw_circle(center + Vector2(0.0, outer_r * 0.12), outer_r * 0.22, lite)
	if is_active:
		for i in 3:
			var ox := (float(i) - 1.0) * outer_r * 0.22
			var ph := fposmod(_flow_phase * 1.8 + float(i) * 0.33, 1.0)
			var dy := lerpf(-outer_r * 0.15, outer_r * 0.55, ph)
			draw_line(center + Vector2(ox, dy), center + Vector2(ox, dy + 6.0 * _zoom),
					Color(1, 1, 1, 0.55), maxf(1.0, 1.5 * _zoom))
	_draw_pbi_labels(center, outer_r * 0.72, title, pbi_val, Color.WHITE, Color(0.9, 0.95, 1.0, 0.95))


## Dynamic weather cloud icon — changes with cloud_frac / rain (forecast style).
func _draw_wind_pbi_body(center: Vector2, outer_r: float, is_active: bool,
		specs: Dictionary, title: String, pbi_val: String) -> void:
	var cloud_frac := clampf(float(specs.get("cloud_frac", 0.0)), 0.0, 1.0)
	var rain_mmh := maxf(0.0, float(specs.get("rain_mmh", 0.0)))
	var wind_ms := maxf(0.0, float(specs.get("wind_ms", 0.0)))
	var wclass := int(specs.get("weather_class",
			AtmospherePbi.weather_visual_class(cloud_frac, rain_mmh)))
	var sky := Color(0.35, 0.62, 0.88)
	if wclass >= 3:
		sky = Color(0.32, 0.40, 0.52)
	elif wclass == 2:
		sky = Color(0.40, 0.55, 0.72)
	draw_circle(center, outer_r * 0.96, sky)
	if is_active:
		draw_circle(center, outer_r * (1.08 + 0.03 * sin(_flow_phase * TAU)),
				Color(sky.r, sky.g, sky.b, 0.22))
	if wclass <= 1:
		var sun_c := center + Vector2(-outer_r * 0.28, -outer_r * 0.22)
		draw_circle(sun_c, outer_r * 0.18, Color(1.0, 0.9, 0.35, 0.95))
	var puff_n := 2 + mini(3, wclass)
	var base_y := center.y + outer_r * 0.02
	var drift := sin(_flow_phase * TAU * 0.35) * outer_r * 0.04 * clampf(wind_ms / 12.0, 0.0, 1.0)
	var cloud_col := Color(0.92, 0.94, 0.97, 0.95)
	if wclass >= 3:
		cloud_col = Color(0.55, 0.58, 0.64, 0.96)
	elif wclass == 2:
		cloud_col = Color(0.78, 0.80, 0.85, 0.95)
	elif wclass == 4:
		cloud_col = Color(0.42, 0.45, 0.52, 0.97)
	var sizes: Array = [0.32, 0.26, 0.22, 0.20, 0.18]
	var offsets: Array = [-0.22, 0.05, 0.28, -0.08, 0.18]
	for i in puff_n:
		var ox: float = float(offsets[i]) * outer_r + drift
		var pr: float = float(sizes[i]) * outer_r * (1.0 + 0.12 * cloud_frac)
		var py: float = base_y + (0.0 if i < 3 else outer_r * 0.06)
		draw_circle(Vector2(center.x + ox, py), pr, cloud_col)
	draw_circle(Vector2(center.x + drift, base_y + outer_r * 0.08),
			outer_r * (0.38 + 0.08 * cloud_frac), cloud_col)
	if wclass >= 4 or rain_mmh > 0.05:
		var streak_n := 5
		for i in streak_n:
			var t := float(i) / float(maxi(streak_n - 1, 1))
			var sx := center.x + lerpf(-outer_r * 0.28, outer_r * 0.28, t) + drift * 0.5
			var ph := fposmod(_flow_phase * 2.2 + t * 0.4, 1.0)
			var sy0 := base_y + outer_r * 0.22 + ph * outer_r * 0.15
			draw_line(Vector2(sx, sy0), Vector2(sx - 2.0 * _zoom, sy0 + 10.0 * _zoom),
					Color(0.75, 0.85, 1.0, 0.7), maxf(1.0, 1.6 * _zoom))
	if wind_ms > 2.0:
		var ticks := 3 + int(clampf(wind_ms / 4.0, 0.0, 4.0))
		for i in ticks:
			var a := -0.35 + float(i) * 0.18 + _flow_phase * 0.5
			var p0 := center + Vector2(cos(a), sin(a)) * outer_r * 0.78
			var p1 := center + Vector2(cos(a), sin(a)) * outer_r * 0.92
			draw_line(p0, p1, Color(1, 1, 1, 0.45), maxf(1.0, 1.4 * _zoom))
	draw_arc(center, outer_r * 0.96, 0.0, TAU, 48, Color(1, 1, 1, 0.18), maxf(1.0, 1.5 * _zoom))
	_draw_pbi_labels(center, outer_r * 0.70, title, pbi_val,
			Color(1, 1, 1, 1.0), Color(0.95, 0.98, 1.0, 0.95))

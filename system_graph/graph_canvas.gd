extends Control
## GraphCanvas — pan/zoom drawing area for the solar circuit graph.
##
## Renders all graph items and connections stored in the GraphModel.
## Interactions: pan (MMB/RMB), zoom (wheel),
## item selection/drag (LMB), wire drag-to-connect (port dot LMB).

# ResourceKinds — global class_name from system_graph/data/resource_kinds.gd

## Preloaded rather than reached through its global class name: this script is
## itself preloaded by offline selftests, where global class registration is not
## guaranteed to have happened yet (the "Identifier not found" trap).
const _UI_SFX := preload("res://core/ui_sfx.gd")

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
# DC terminal convention: on every type that carries a +/− pair, POSITIVE sits
# on the LEFT (rx 0.25) and NEGATIVE on the right (0.75). Batteries and
# controllers were already laid out that way; generators used to be mirrored,
# which crossed both wires on the commonest link in the game (panel →
# controller). Pinned by graph_wire_routing_selftest.
const HANDLES := {
	"panel": [
		{"id": "positive", "polarity": "positive", "rx": 0.25, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.75, "ry": 1.0},
		# Optional, non-blocking — sunlight reaches every panel in the SoI
		# ambiently (mirrors real life: nothing "pipes" sunlight). Drawing
		# this wire from the sun PBI is purely visual/documentary and is
		# NEVER required for the panel to produce; see solar_pbi_selftest.gd.
		{"id": "sunlight_in", "polarity": "resource", "resource_kind": "sunlight", "rx": 0.5, "ry": 0.0},
	],
	# Wind/hydro generators wire like panels: DC out the bottom into a
	# controller PV input or a combiner.
	"wind": [
		{"id": "positive", "polarity": "positive", "rx": 0.25, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.75, "ry": 1.0},
		# Optional ambient atmosphere link from Wind PBI — turbines already
		# read WeatherService; this wire is documentary only.
		{"id": "wind_in", "polarity": "resource", "resource_kind": "wind", "rx": 0.5, "ry": 0.0},
	],
	"hydro": [
		{"id": "positive", "polarity": "positive", "rx": 0.25, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.75, "ry": 1.0},
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
## At high sim speeds, full-canvas redraw + chase trails dominate CPU; drop to
## ~6–8 fps and force wire simplify so 1440×/Max stay interactive.
const REDRAW_INTERVAL_HIGH_SPEED := 0.15
## flow_mult units = sim× over realtime (see tick()); ≥300× triggers high-speed LOD.
const HIGH_SPEED_FLOW_MULT := 300.0
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
## Also simplify when zoomed WAY in (Elevation megapixel era) — width∝zoom
## otherwise floods fill-rate even with few wires.
const WIRE_LOD_ZOOM_HIGH := 4.0
## Screen-px caps so Elevation strokes/chips don't grow with zoom forever.
const ELEV_WIRE_MAX_PX := 8.0
const ELEV_STROKE_MAX_PX := 6.0
const ELEV_CHIP_MAX_PX := 96.0
const ELEV_CHIP_MIN_PX := 28.0
const ELEV_CHIP_MIN_H_PX := 16.0
## Compact elev pads (chips off): hit floors stay small so ports don't own the disc.
const ELEV_HIT_MIN_PX := 14.0
const ELEV_PORT_GRAB_MIN_PX := 5.0
const ELEV_PORT_GRAB_MAX_PX := 9.0
## Faster wheel than freeform 1.08 — deep elev detail needs big steps.
const ELEV_WHEEL_ZOOM := 1.22
const PHYS_WIRE_CORNER_MAX_PX := 14.0
var _wire_lod_simplify: bool = false
## Set each tick when sim speed is high — forces wire simplify + thinner dashes.
var _high_speed_lod: bool = false
## Baked DEM section profile (invalidate on heading/offset/SoI/DEM — not pan/zoom).
var _elev_along: PackedFloat32Array = PackedFloat32Array()
var _elev_y: PackedFloat32Array = PackedFloat32Array()
var _elev_bake_key: String = ""
## Elevation deep-zoom: content is relative to this metre-space focus so
## `(along - anchor) * s` stays small (no float blow-up / pan discontinuity).
var _elev_anchor_along_m: float = 0.0
var _elev_anchor_elev_m: float = NAN
var _elev_anchor_inited: bool = false
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
## Site view (orbited): world-ground site metres under the cursor at drag start,
## so camera-projected drags keep the per-item offset from the pointer.
var _item_drag_cursor_site_start: Vector2 = Vector2.ZERO
## Elevation view (orbited): section-plane hit under the cursor at drag start
## `{site_x_m, site_z_m, elevation_m}` so tilt-aware drags stay under the pointer.
var _item_drag_cursor_elev_start: Dictionary = {}
var _marquee_selecting:     bool = false
var _marquee_start:         Vector2 = Vector2.ZERO
var _marquee_end:           Vector2 = Vector2.ZERO
## Screen-space hit rects for destroyed-controller Reset buttons (cleared each draw).
var _controller_reset_rects: Dictionary = {}
## "<item_id>|<handle_id>" set of ambient documentary ports that carry a wire —
## see _refresh_ambient_wired_ports / is_ambient_doc_handle.
var _ambient_wired_ports: Dictionary = {}
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
## Zoom-out past a floor while inside a sub-canvas — pop up to the parent scope.
signal scope_pop_requested()
signal layout_changed()
signal resource_containers_merged(target_id: String, absorbed_id: String, kind: String)
signal controller_reset_pressed(item_id: String)
## SoI live preview camera — Shift+drag orbit, Shift+wheel zoom.
signal soi_preview_orbit(relative: Vector2)
signal soi_preview_zoom(zoom_in: bool)
## Elevation: Shift+drag rotates the section heading (continuous).
signal elevation_heading_changed(heading_rad: float)
## Siphon Lab: Elev chord/water drag updated specs (kind, item_id, elev_m).
signal lab_level_dragged(kind: String, item_id: String, elev_m: float)
## Elevation CT: slice depth along the cross-axis (−R…+R metres).
signal elevation_section_offset_changed(offset_m: float)
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
## CT slice depth along the cross-axis (−SoI radius…+radius metres).
var elevation_section_offset_m: float = 0.0
## Vertical exaggeration for elevation profile (1 or 5).
## When Elev 3D section is on, draw/pan use 1× via `_elev_exaggeration_draw()`.
var elevation_exaggeration: float = 5.0
## Elevation overlay visibility (View options ▾). Defaults match Elev 3D on.
var elev_show_dem_overlay: bool = true
var elev_show_chips: bool = false
var elev_show_ports: bool = false
## Site Plan: show node port dots. Off = tidy (wires still draw — separate path).
var site_show_ports: bool = true
var elev_show_schematic_wires: bool = false
var elev_show_projected_pipes: bool = false
## True while Siphon Lab dock is open (same Elev CT; draws prime/break ticks).
var siphon_lab_active: bool = false
## Hit targets for Lab level drag (rebuilt each Elev draw).
var _lab_level_hits: Array = []
var _lab_pond_level_hit: Dictionary = {}
var _lab_level_dragging: bool = false
var _lab_level_drag_kind: String = ""
var _lab_level_drag_item_id: String = ""
var _lab_level_drag_start_y: float = 0.0
var _lab_level_drag_start_elev: float = 0.0
## Current visible graph scope. Root matches historical behavior.
var active_scope_id: String  = "root"

## Global wire-style override (set by the toolbar "Wire style" control). Empty
## string = use each connection's own `line_style`; otherwise this value
## ("bezier" | "orthogonal" | "metro") is drawn for EVERY connection without
## mutating the model, so the choice is a live, reversible view preference. Use
## `_effective_line_style(conn)` everywhere a connection's style is read.
var wire_style_override: String = ""


## Resolve the drawn style for a connection: the global override wins when set,
## otherwise the connection's own persisted `line_style`.
func _effective_line_style(conn: Dictionary) -> String:
	# Site Plan metro overlay forces freeform-style metro ribbons.
	if view_mode == GraphSiteLayout.VIEW_SITE and site_wire_mode == "metro":
		return "metro"
	if not wire_style_override.is_empty():
		return wire_style_override
	return str(conn.get("line_style", "bezier"))


## True when Site Plan should draw 2D schematic wires (metro overlay).
func _site_draws_schematic_wires() -> bool:
	return view_mode == GraphSiteLayout.VIEW_SITE and site_wire_mode == "metro"


## Node body rendering for model-bearing nodes: "preview" = full-bleed GLB
## thumbnail (default); "card" = classic framed node card. View options ▾.
var node_display_mode: String = "preview"
## Title band on full-bleed preview nodes (View options ▾ toggle).
var show_preview_labels: bool = true
## Freeform-only display scale for the SoI reference ring. Shift+scroll (with
## the SoI bubble preview OFF) resizes just the ring; plain scroll zooms both.
var soi_ring_scale: float = 1.0
## Site Plan radial layout: dragging a bound node auto-yaws its 3D twin
## tangential to the circle around the SoI center (radially planned sites —
## e.g. Burning Man — without hand-tuning every model's yaw).
var radial_layout_mode: bool = false
## Site Plan: show labels on magnifier rings (rings themselves always draw).
var site_show_chips: bool = true
## Site Plan wire overlay: none | metro | prefer_3d (default metro → 2D wires to rings).
var site_wire_mode: String = "metro"
## Optional: live-sync bound 3D twin while a Site Plan magnifier is dragged.
## Signature: (item_id: String, site_xz: Vector2) -> void
var site_drag_sync_prop: Callable = Callable()
## Hovered graph item id in Site Plan (magnifier glow).
var _site_hover_item_id: String = ""
## Working radius (m) for radial guides / array — independent of SoI R.
var site_working_radius_m: float = NAN
## Optional GraphSpatialEdit (SystemGraphView) for 3D prop pick/drag in Site/Elev.
var spatial_edit = null
## Array ghost previews from spatial_edit (site metres → drawn each frame).
var site_array_ghosts: Array = []

## When true, PBI (fundamental resource) nodes are drawn as a fixed screen-space
## bar pinned along the top of the canvas rather than floating in graph space.
## Set by SystemGraphView from the "Show PBI bar" toggle + save state.
var pbi_bar_pinned: bool = true

## Screen rects + resolved output-port info of the pinned PBI pills for the
## current draw, so hit-testing (wire-drop / click-select) works against the bar.
## item_id -> {rect: Rect2, port: Dictionary(handle info)}
var _pbi_pill_rects: Dictionary = {}


## True when PBI nodes should be pinned to the top bar instead of drawn in the
## graph. Only meaningful at the root scope (PBIs live at root).
func _pbi_pinned_active() -> bool:
	return pbi_bar_pinned and active_scope_id == "root"

var _flow_phase:   float = 0.0
var _redraw_accum: float = 0.0

# ---------------------------------------------------------------------------
# Shared styleboxes
# ---------------------------------------------------------------------------
var _sb_node_base: StyleBoxFlat
## Reused for running/alert state halos (rounded to match node corner radius).
var _sb_state_highlight: StyleBoxFlat


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
	_sb_state_highlight = StyleBoxFlat.new()
	_sb_state_highlight.set_corner_radius_all(12)


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
	_high_speed_lod = flow_mult >= HIGH_SPEED_FLOW_MULT
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
	var fx_hot := false
	for i in range(_destroy_fx.size() - 1, -1, -1):
		var fx: Dictionary = _destroy_fx[i]
		fx["age"] = float(fx.get("age", 0.0)) + delta
		if float(fx["age"]) > FX_LIFETIME:
			_destroy_fx.remove_at(i)
		else:
			fx_alive = true
			if float(fx["age"]) < FX_FULL_RATE_S:
				fx_hot = true
	# Alert pulse advances independently of test-mode flow so faulted/starved
	# nodes still breathe while paused — but only drives a coarse ~10 fps redraw,
	# not the 20 fps interactive loop.
	if _alert_nodes_present:
		_alert_phase = fmod(_alert_phase + delta * 1.6, TAU)
	_redraw_accum += delta
	var interval := 0.25
	if fx_hot:
		# An explosion at the normal 20 fps cadence reads as a slideshow.
		interval = 0.0
	elif current_mode == "test" or _needs_continuous_redraw or fx_alive:
		interval = REDRAW_INTERVAL_HIGH_SPEED if _high_speed_lod else REDRAW_INTERVAL
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


func get_elev_anchor_along_m() -> float:
	return _elev_anchor_along_m


func get_elev_anchor_elev_m() -> float:
	if is_nan(_elev_anchor_elev_m):
		return _elevation_datum_m()
	return _elev_anchor_elev_m


func has_elev_anchor() -> bool:
	return _elev_anchor_inited and not is_nan(_elev_anchor_elev_m)


## Keep SoI section camera locked to Elev metre anchors.
## Dirty-flag only — force_layout_sync every wheel notch re-crops the SubViewport
## and fights fast deep zoom (stutter + lost cursor focus).
func _notify_elev_soi_layout() -> void:
	if soi_preview_service == null or not is_instance_valid(soi_preview_service):
		return
	if soi_preview_service.has_method("mark_layout_dirty"):
		soi_preview_service.call("mark_layout_dirty")


## One-shot re-capture of the live 3D disc — used when a spatial-edit prop drag /
## hover mutates the shared World3D directly, so the change shows immediately
## instead of only on the next zoom (layout dirty).
func _refresh_soi_preview() -> void:
	if soi_preview_service != null and is_instance_valid(soi_preview_service) \
			and soi_preview_service.has_method("request_refresh"):
		soi_preview_service.call("request_refresh")


## Snapshot / restore Elevation CT pan+zoom (Siphon Lab save/restore).
func get_elev_view_state() -> Dictionary:
	_ensure_elev_anchor()
	return {
		"zoom": _zoom,
		"along_m": _elev_anchor_along_m,
		"elev_m": get_elev_anchor_elev_m(),
	}


func set_elev_view_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	_zoom = clampf(float(state.get("zoom", _zoom)), ZOOM_MIN, ZOOM_MAX)
	_elev_anchor_along_m = float(state.get("along_m", _elev_anchor_along_m))
	_elev_anchor_elev_m = float(state.get("elev_m", get_elev_anchor_elev_m()))
	_elev_anchor_inited = true
	_pan = Vector2.ZERO
	queue_redraw()
	if soi_preview_service != null and is_instance_valid(soi_preview_service) \
			and soi_preview_service.has_method("mark_layout_dirty"):
		soi_preview_service.call("mark_layout_dirty")


## Fit an along/elev metre window into `viewport_size` (Lab CT slot or canvas).
func frame_elevation_window(along0: float, along1: float, y0: float, y1: float,
		viewport_size: Vector2, margin: float = 0.12) -> void:
	var a0 := minf(along0, along1)
	var a1 := maxf(along0, along1)
	var e0 := minf(y0, y1)
	var e1 := maxf(y0, y1)
	var along_span := maxf((a1 - a0) * (1.0 + 2.0 * margin), 2.0)
	var elev_span := maxf((e1 - e0) * (1.0 + 2.0 * margin), 2.0)
	var vw := maxf(viewport_size.x, 8.0)
	var vh := maxf(viewport_size.y, 8.0)
	var s := minf(vw / along_span, vh / elev_span)
	_zoom = clampf(s / GraphSiteLayout.SOI_PX_PER_M, ZOOM_MIN, ZOOM_MAX)
	_elev_anchor_along_m = (a0 + a1) * 0.5
	_elev_anchor_elev_m = (e0 + e1) * 0.5
	_elev_anchor_inited = true
	# Elev disc chrome is viewport-centred — leftover freeform pan draws a
	# second offset SoI ring (the "double circle" on first Elev enter).
	_pan = Vector2.ZERO
	queue_redraw()
	_notify_elev_soi_layout()


## Public wrappers so Siphon Lab can pan/zoom the shared Elev CT camera.
func elev_pan_by_pixels(delta_px: Vector2) -> void:
	_elev_pan_by_pixels(delta_px)
	queue_redraw()


func elev_zoom_at_screen(factor: float, screen_pos: Vector2,
		viewport_size: Vector2 = Vector2.ZERO) -> void:
	if viewport_size.x > 1.0 and viewport_size.y > 1.0:
		_elev_zoom_at_in_viewport(factor, screen_pos, viewport_size)
	else:
		_elev_zoom_at(factor, screen_pos)
	queue_redraw()


func _ensure_elev_anchor() -> void:
	if _elev_anchor_inited:
		return
	_elev_anchor_inited = true
	if is_nan(_elev_anchor_elev_m):
		_elev_anchor_elev_m = _elevation_datum_m()
	# Migrate legacy pixel pan → metre anchor (screen = vc + pan + along*s
	# matched vc + (along - anchor)*s ⇒ anchor = -pan.x/s for along=0).
	var s := GraphSiteLayout.px_per_m(_zoom)
	if s > 1e-6 and _pan.length_squared() > 1.0:
		_elev_anchor_along_m = -_pan.x / s
		var ex := _elev_exaggeration_draw()
		_elev_anchor_elev_m = _elevation_datum_m() + _pan.y / (s * ex)
		_pan = Vector2.ZERO


func _elev_pan_by_pixels(delta_px: Vector2) -> void:
	_ensure_elev_anchor()
	var s := GraphSiteLayout.px_per_m(_zoom)
	if s < 1e-6:
		return
	var ex := _elev_exaggeration_draw()
	_elev_anchor_along_m -= delta_px.x / s
	_elev_anchor_elev_m += delta_px.y / (s * ex)
	_notify_elev_soi_layout()


func _elev_zoom_at(factor: float, screen_pos: Vector2) -> void:
	_ensure_elev_anchor()
	var old_zoom := _zoom
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(_zoom, old_zoom):
		return
	var vc := size * 0.5
	var s_old := GraphSiteLayout.px_per_m(old_zoom)
	var s_new := GraphSiteLayout.px_per_m(_zoom)
	var ex := _elev_exaggeration_draw()
	# Metre under cursor stays fixed.
	var along := _elev_anchor_along_m + (screen_pos.x - vc.x) / maxf(s_old, 1e-6)
	var elev := _elev_anchor_elev_m - (screen_pos.y - vc.y) / maxf(s_old * ex, 1e-6)
	_elev_anchor_along_m = along - (screen_pos.x - vc.x) / maxf(s_new, 1e-6)
	_elev_anchor_elev_m = elev + (screen_pos.y - vc.y) / maxf(s_new * ex, 1e-6)
	_pan = Vector2.ZERO
	_notify_elev_soi_layout()
	queue_redraw()


## Like `_elev_zoom_at`, but focal maths use an external viewport (Siphon Lab CT).
func _elev_zoom_at_in_viewport(factor: float, screen_pos: Vector2,
		viewport_size: Vector2) -> void:
	_ensure_elev_anchor()
	var old_zoom := _zoom
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(_zoom, old_zoom):
		return
	var vc := viewport_size * 0.5
	var s_old := GraphSiteLayout.px_per_m(old_zoom)
	var s_new := GraphSiteLayout.px_per_m(_zoom)
	var ex := _elev_exaggeration_draw()
	var along := _elev_anchor_along_m + (screen_pos.x - vc.x) / maxf(s_old, 1e-6)
	var elev := _elev_anchor_elev_m - (screen_pos.y - vc.y) / maxf(s_old * ex, 1e-6)
	_elev_anchor_along_m = along - (screen_pos.x - vc.x) / maxf(s_new, 1e-6)
	_elev_anchor_elev_m = elev + (screen_pos.y - vc.y) / maxf(s_new * ex, 1e-6)
	_pan = Vector2.ZERO
	_notify_elev_soi_layout()


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
const _ELEV_OFFSET_SENS := 0.35


func _handle_elevation_heading_input(event: InputEvent) -> bool:
	# Siphon Lab: lock side cut — no Shift+drag heading/slice (wheel zoom OK).
	if siphon_lab_active:
		if event is InputEventMouseButton:
			var mb_lab := event as InputEventMouseButton
			if mb_lab.shift_pressed and soi_live_preview \
					and (mb_lab.button_index == MOUSE_BUTTON_WHEEL_UP \
					or mb_lab.button_index == MOUSE_BUTTON_WHEEL_DOWN) \
					and mb_lab.pressed:
				soi_preview_zoom.emit(mb_lab.button_index == MOUSE_BUTTON_WHEEL_UP)
				accept_event()
				return true
			if mb_lab.shift_pressed and mb_lab.button_index == MOUSE_BUTTON_LEFT:
				accept_event()
				return true
		if event is InputEventMouseMotion and (event as InputEventMouseMotion).shift_pressed:
			accept_event()
			return true
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# Shift+wheel zooms the 3D section ortho into the cut face.
		if mb.shift_pressed and soi_live_preview \
				and (mb.button_index == MOUSE_BUTTON_WHEEL_UP \
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN) and mb.pressed:
			soi_preview_zoom.emit(mb.button_index == MOUSE_BUTTON_WHEEL_UP)
			accept_event()
			return true
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
		# Vertical drag scrubs CT slice depth (−R…+R), not camera pitch.
		if not is_equal_approx(mm.relative.y, 0.0):
			var r_m := 150.0
			var soi_svc := _cached_autoload("/root/SoiService")
			if soi_svc != null and soi_svc.has_method("radius_m"):
				r_m = float(soi_svc.call("radius_m"))
			elevation_section_offset_m = clampf(
					elevation_section_offset_m - mm.relative.y * _ELEV_OFFSET_SENS,
					-r_m, r_m)
			elevation_section_offset_changed.emit(elevation_section_offset_m)
		queue_redraw()
		accept_event()
		return true
	return false


func _handle_lab_level_drag_input(event: InputEvent) -> bool:
	if model == null:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if not mb.pressed:
			if _lab_level_dragging:
				# Final sync for dock SpinBoxes.
				if model != null and not _lab_level_drag_item_id.is_empty():
					var fin := model.get_item(_lab_level_drag_item_id)
					var fs: Dictionary = fin.get("specs", {}) as Dictionary
					var elev := float(fs.get("siphon_start_m" if _lab_level_drag_kind == "prime" \
							else ("siphon_break_m" if _lab_level_drag_kind == "break" \
							else "level_m"), NAN))
					if not is_nan(elev):
						lab_level_dragged.emit(_lab_level_drag_kind,
								_lab_level_drag_item_id, elev)
				_lab_level_dragging = false
				_lab_level_drag_kind = ""
				_lab_level_drag_item_id = ""
				accept_event()
				return true
			return false
		if mb.shift_pressed:
			return false
		var hit := _lab_level_hit_at(mb.position)
		if hit.is_empty():
			return false
		_lab_level_dragging = true
		_lab_level_drag_kind = str(hit.get("kind", ""))
		_lab_level_drag_item_id = str(hit.get("item_id", ""))
		_lab_level_drag_start_y = mb.position.y
		_lab_level_drag_start_elev = float(hit.get("elev_m", 0.0))
		accept_event()
		return true
	if event is InputEventMouseMotion:
		if not _lab_level_dragging:
			return false
		var mm := event as InputEventMouseMotion
		var s := GraphSiteLayout.px_per_m(_zoom)
		var ex := _elev_exaggeration_draw()
		var px_per_m := maxf(s * ex, 1e-6)
		# Screen Y down → elevation down.
		var d_elev := -((mm.position.y - _lab_level_drag_start_y) / px_per_m)
		var new_elev := _lab_level_drag_start_elev + d_elev
		_apply_lab_level_drag(new_elev)
		accept_event()
		return true
	return false


func _lab_level_hit_at(pos: Vector2) -> Dictionary:
	const PAD := 8.0
	for h in _lab_level_hits:
		if not (h is Dictionary):
			continue
		var d: Dictionary = h
		if pos.x < float(d.get("x0", 0.0)) or pos.x > float(d.get("x1", 0.0)):
			continue
		if absf(pos.y - float(d.get("y_px", 0.0))) <= PAD:
			return d
	if not _lab_pond_level_hit.is_empty():
		var p := _lab_pond_level_hit
		if pos.x >= float(p.get("x0", 0.0)) and pos.x <= float(p.get("x1", 0.0)) \
				and absf(pos.y - float(p.get("y_px", 0.0))) <= PAD:
			return {
				"kind": "pond",
				"item_id": str(p.get("item_id", "")),
				"elev_m": float(p.get("level_m", 0.0)),
			}
	return {}


func _apply_lab_level_drag(new_elev: float) -> void:
	if model == null or _lab_level_drag_item_id.is_empty():
		return
	var kind := _lab_level_drag_kind
	if kind == "prime" or kind == "break":
		var item := model.get_item(_lab_level_drag_item_id)
		if item.is_empty():
			return
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var key := "siphon_start_m" if kind == "prime" else "siphon_break_m"
		var other_key := "siphon_break_m" if kind == "prime" else "siphon_start_m"
		var other := float(specs.get(other_key, new_elev))
		if kind == "prime":
			new_elev = maxf(new_elev, other + 0.02)
		else:
			new_elev = minf(new_elev, other - 0.02)
		specs[key] = new_elev
		model.update_item(_lab_level_drag_item_id, {"specs": specs})
		lab_level_dragged.emit(kind, _lab_level_drag_item_id, new_elev)
		queue_redraw()
		return
	if kind == "pond":
		var tank := model.get_item(_lab_level_drag_item_id)
		if tank.is_empty():
			return
		var ts: Dictionary = (tank.get("specs", {}) as Dictionary).duplicate(true)
		var floor_y := float(ts.get("floor_m", NAN))
		var rim := float(ts.get("rim_m", NAN))
		if is_nan(floor_y):
			floor_y = new_elev - 1.0
		if is_nan(rim):
			rim = new_elev + 0.5
		new_elev = clampf(new_elev, floor_y + 0.02, rim - 0.02)
		var span := maxf(rim - floor_y, 0.05)
		var frac := clampf((new_elev - floor_y) / span, 0.0, 1.0)
		var cap := maxf(float(ts.get("capacity_qty", 1.0)), 1.0)
		ts["level_m"] = new_elev
		ts["level"] = frac
		ts["stock_l"] = frac * cap
		# Dragging the CT water line re-anchors the pond level; the flow engine
		# then continues fill/drain from here on the world clock (fill_mode auto).
		ts["fill_mode"] = "auto"
		ts["overflowing"] = false
		model.update_item(_lab_level_drag_item_id, {"specs": ts, "elevation_m": new_elev})
		if resource_flow_engine != null and resource_flow_engine.has_method("reanchor_tank"):
			resource_flow_engine.call("reanchor_tank", _lab_level_drag_item_id, frac)
		var host: Node = get_parent()
		while host != null and not host.has_method("push_pond_levels_to_mesh"):
			host = host.get_parent()
		if host != null:
			host.call("push_pond_levels_to_mesh", true)
		lab_level_dragged.emit(kind, _lab_level_drag_item_id, new_elev)
		queue_redraw()


## Site/Elev: pick & drag 3D props via GraphSpatialEdit before chip/orbit paths.
## Site Plan: magnifier rings win over 3D prop pick when a placed item is under
## the cursor; 3D drag remains the fallback for orphan props / empty space.
func _handle_spatial_edit_input(event: InputEvent) -> bool:
	if spatial_edit == null or not _is_physical_view():
		return false
	if not spatial_edit.has_method("is_dragging"):
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if view_mode == GraphSiteLayout.VIEW_SITE:
				var mag := _item_at_screen(mb.position)
				if not mag.is_empty() and GraphSiteLayout.has_site_coords(mag) \
						and not _is_watershed_item(mag):
					return false
			# Shift+empty = orbit (SoI handler). Prop under cursor = drag (+ Shift yaw).
			if spatial_edit.has_method("begin_prop_drag") \
					and bool(spatial_edit.call("begin_prop_drag", mb.position, mb.shift_pressed)):
				accept_event()
				queue_redraw()
				_refresh_soi_preview()
				return true
			# 3D conduit under cursor → select the graph connection (no 2D wire hit).
			if spatial_edit.has_method("pick_at_canvas"):
				var spat: Dictionary = spatial_edit.call("pick_at_canvas", mb.position) \
						as Dictionary
				if str(spat.get("kind", "")) == "conduit":
					var cid := str(spat.get("id", ""))
					if not cid.is_empty():
						_select_connection(cid)
						accept_event()
						queue_redraw()
						return true
			return false
		if bool(spatial_edit.call("is_dragging")):
			if spatial_edit.has_method("end_prop_drag"):
				spatial_edit.call("end_prop_drag")
			accept_event()
			layout_changed.emit()
			queue_redraw()
			_refresh_soi_preview()
			return true
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if bool(spatial_edit.call("is_dragging")):
			if spatial_edit.has_method("drag_to"):
				spatial_edit.call("drag_to", mm.position, mm.shift_pressed)
			accept_event()
			queue_redraw()
			# Re-capture the disc so the moved/rotated prop shows live (the move is
			# already applied to the real 3D node; without this it only appears on zoom).
			_refresh_soi_preview()
			return true
		if view_mode == GraphSiteLayout.VIEW_SITE:
			_update_site_hover(mm.position)
		if spatial_edit.has_method("update_hover"):
			spatial_edit.call("update_hover", mm.position)
	return false


func _update_site_hover(screen_pos: Vector2) -> void:
	var hit := _item_at_screen(screen_pos)
	var hid := str(hit.get("id", "")) if not hit.is_empty() \
			and GraphSiteLayout.has_site_coords(hit) else ""
	if hid == _site_hover_item_id:
		return
	_site_hover_item_id = hid
	queue_redraw()


func _is_watershed_item(item: Dictionary) -> bool:
	if item.is_empty():
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	return str(item.get("type", "")) == "catchment" \
			and str(specs.get("catchment_kind", "")) == "watershed"


## Pond import creates a surface catchment + storage tank (+ optional hillside
## watershed). In Site/Elev physical views those catchments are twins of the
## tank — hide them so one pond doesn't draw as two/three outlines.
func _is_pond_twin_hidden(item: Dictionary) -> bool:
	if item.is_empty() or model == null or not _is_physical_view():
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if str(item.get("type", "")) != "catchment":
		return false
	var kind := str(specs.get("catchment_kind", ""))
	if kind != "pond" and kind != "watershed":
		return false
	var tag := str(specs.get("pond_tag", ""))
	if tag.is_empty():
		tag = str(specs.get("osm_water_tag", specs.get("osm_tag", "")))
	if tag.begins_with("watershed_"):
		tag = tag.trim_prefix("watershed_")
	if tag.is_empty():
		return false
	var pond_id := str(specs.get("pond_id", ""))
	for it in model.items:
		if not (it is Dictionary):
			continue
		var os: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if not bool(os.get("pond_storage", false)):
			continue
		if str(os.get("osm_water_tag", "")) == tag:
			return true
		if not pond_id.is_empty() and str(os.get("pond_id", "")) == pond_id:
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

	# Siphon Lab: drag Prime/Break/pond level on Elev CT (before SoI camera).
	if siphon_lab_active and _handle_lab_level_drag_input(event):
		return

	# Site/Elev 3D prop pick/drag (wins over chip hits + Shift+orbit while dragging).
	if _handle_spatial_edit_input(event):
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
		# Zoom. In plain freeform (no SoI bubble preview — that path consumed
		# Shift+wheel above), Shift+scroll resizes ONLY the SoI reference ring;
		# plain scroll zooms nodes + ring together.
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if mb.shift_pressed and view_mode == GraphSiteLayout.VIEW_FREEFORM:
				soi_ring_scale = clampf(soi_ring_scale * 1.08, 0.25, 4.0)
				layout_changed.emit()
				queue_redraw();  accept_event();  return
			var zf := _wheel_zoom_factor()
			_zoom_at(zf, mb.position);  accept_event();  return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mb.shift_pressed and view_mode == GraphSiteLayout.VIEW_FREEFORM:
				soi_ring_scale = clampf(soi_ring_scale / 1.08, 0.25, 4.0)
				layout_changed.emit()
				queue_redraw();  accept_event();  return
			var zf2 := _wheel_zoom_factor()
			_zoom_at(1.0 / zf2, mb.position);  accept_event();  return
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
		# BACKSPACE only, deliberately. Delete on a selected wire deletes the
		# WIRE: system_graph_view.gd handles KEY_DELETE in _input(), which runs
		# before _gui_input, so a KEY_DELETE branch here was unreachable dead
		# code that made the two keys silently do different things on the same
		# selection. Backspace = pop the last waypoint is the surviving,
		# intentional behaviour.
		if event.keycode == KEY_BACKSPACE and not selected_connection_id.is_empty():
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
		var dmid := mid - _touch_pan_last_mid
		if view_mode == GraphSiteLayout.VIEW_ELEVATION:
			_elev_pan_by_pixels(dmid)
		else:
			_pan += dmid
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
				if _effective_line_style(conn) == "metro":
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
		var dpan := screen_pos - _last_drag_pos
		_last_drag_pos = screen_pos
		if view_mode == GraphSiteLayout.VIEW_ELEVATION:
			_elev_pan_by_pixels(dpan)
		else:
			_pan += dpan
		queue_redraw()
	elif _wire_dragging:
		_on_wire_drag_move(screen_pos)
	elif _item_dragging:
		_on_item_drag_move(screen_pos)
	elif _marquee_selecting:
		_marquee_end = screen_pos
		queue_redraw()
	elif view_mode == GraphSiteLayout.VIEW_SITE:
		_update_site_hover(screen_pos)


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


## Drill-in / pop-out thresholds (fraction of viewport a super-node must cover).
const ZOOM_DRILL_COVER := 0.82
const ZOOM_POP_COVER := 0.42


func _zoom_at(factor: float, screen_pos: Vector2) -> void:
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		_elev_zoom_at(factor, screen_pos)
		return
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
	# Seamless TouchDesigner-style scope navigation via zoom.
	# Site/Elev: zoom scales metres — never drill.
	# Freeform: always allow drill/pop, even with SoI bubble behind nodes
	# (soi_live_preview). Shift+wheel already owns 3D bubble orbit/zoom.
	if view_mode == GraphSiteLayout.VIEW_FREEFORM:
		if factor > 1.0:
			_maybe_zoom_drill_in(screen_pos)
		elif factor < 1.0:
			_maybe_zoom_pop_out()
	# SoI preview polls disc radius_px (includes zoom) each frame — do not emit
	# layout_changed here (that path autosaves + resyncs 3D props).


## When a generic super-node under the cursor grows to nearly fill the viewport,
## enter it (its child canvas replaces the view). The view then fits the scope.
func _maybe_zoom_drill_in(screen_pos: Vector2) -> void:
	if model == null:
		return
	var hit := _item_at_screen(screen_pos)
	if hit.is_empty() or str(hit.get("type", "")) != "compound":
		return
	if str((hit.get("specs", {}) as Dictionary).get("compound_kind", "")) != "":
		return
	if str(hit.get("child_scope_id", "")).is_empty():
		return
	var center := size * 0.5
	var tl := _item_screen_tl(hit, center)
	var sz := _item_screen_size(hit)
	if not Rect2(tl, sz).has_point(screen_pos):
		return
	if sz.x >= size.x * ZOOM_DRILL_COVER or sz.y >= size.y * ZOOM_DRILL_COVER:
		compound_open_requested.emit(str(hit.get("id", "")))


## Harness/tests: frame a compound to ≥ ZOOM_DRILL_COVER and fire zoom-drill.
## Returns true when cover threshold was met (emit fired; view enters async).
func prepare_and_try_zoom_drill(item_id: String) -> bool:
	if model == null or item_id.is_empty():
		return false
	if view_mode != GraphSiteLayout.VIEW_FREEFORM:
		return false
	var it := model.get_item(item_id)
	if it.is_empty() or str(it.get("type", "")) != "compound":
		return false
	if str((it.get("specs", {}) as Dictionary).get("compound_kind", "")) != "":
		return false
	if str(it.get("child_scope_id", "")).is_empty():
		return false
	var gw := maxf(float(it.get("width", 120.0)), 8.0)
	var gh := maxf(float(it.get("height", 90.0)), 8.0)
	var gc := Vector2(
		float(it.get("x", 0.0)) + gw * 0.5,
		float(it.get("y", 0.0)) + gh * 0.5)
	# Fill ~90% of the shorter viewport axis so cover clears ZOOM_DRILL_COVER.
	var cover := 0.90
	var z := maxf(size.x * cover / gw, size.y * cover / gh)
	_zoom = clampf(z, ZOOM_MIN, ZOOM_MAX)
	_pan = -gc * _zoom
	queue_redraw()
	var screen_pos := size * 0.5
	var sz2 := _item_screen_size(it)
	var covered := sz2.x >= size.x * ZOOM_DRILL_COVER \
			or sz2.y >= size.y * ZOOM_DRILL_COVER
	if covered:
		_maybe_zoom_drill_in(screen_pos)
	return covered


## When the whole active sub-canvas shrinks below a fraction of the viewport,
## pop up to the parent scope (mirrors drilling back out).
func _maybe_zoom_pop_out() -> void:
	if model == null or active_scope_id == "root":
		return
	var bbox := _scope_content_screen_bbox(active_scope_id)
	if bbox.size == Vector2.ZERO:
		return
	if bbox.size.x <= size.x * ZOOM_POP_COVER and bbox.size.y <= size.y * ZOOM_POP_COVER:
		scope_pop_requested.emit()


## Screen-space bounding box of every item currently in `scope_id` (empty rect
## with zero size when the scope has no items).
func _scope_content_screen_bbox(scope_id: String) -> Rect2:
	if model == null:
		return Rect2()
	var kids: Array = model.get_items_in_scope(scope_id)
	if kids.is_empty():
		return Rect2()
	var center := size * 0.5
	var min_p := Vector2(1e20, 1e20)
	var max_p := Vector2(-1e20, -1e20)
	for k_v in kids:
		var k := k_v as Dictionary
		var tl := _item_screen_tl(k, center)
		var sz := _item_screen_size(k)
		min_p = min_p.min(tl)
		max_p = max_p.max(tl + sz)
	return Rect2(min_p, max_p - min_p)


## Graph-coord bounding box (Rect2) of every item in `scope_id`, or a zero-size
## rect when empty. Uses raw x/y/width/height (freeform-canvas coords).
func _scope_content_graph_bbox(scope_id: String) -> Rect2:
	if model == null:
		return Rect2()
	var kids: Array = model.get_items_in_scope(scope_id)
	if kids.is_empty():
		return Rect2()
	var min_p := Vector2(1e20, 1e20)
	var max_p := Vector2(-1e20, -1e20)
	for k_v in kids:
		var k := k_v as Dictionary
		var p := Vector2(float(k.get("x", 0.0)), float(k.get("y", 0.0)))
		var s := Vector2(float(k.get("width", 120.0)), float(k.get("height", 90.0)))
		min_p = min_p.min(p)
		max_p = max_p.max(p + s)
	return Rect2(min_p, max_p - min_p)


## Compute the {zoom, pan} that fits a scope's contents to the viewport with a
## uniform padding fraction, WITHOUT applying it. Returns {"ok": false} when the
## scope is empty / degenerate.
func _scope_fit_view(scope_id: String, pad_frac: float = 0.16) -> Dictionary:
	var gb := _scope_content_graph_bbox(scope_id)
	if gb.size.x <= 1.0 or gb.size.y <= 1.0:
		return {"ok": false}
	var avail := size * (1.0 - pad_frac * 2.0)
	var z := clampf(minf(avail.x / gb.size.x, avail.y / gb.size.y), ZOOM_MIN, ZOOM_MAX)
	var content_center := gb.position + gb.size * 0.5
	# screen(p) = center + _pan + p*_zoom; put content_center at viewport center.
	return {"ok": true, "zoom": z, "pan": -content_center * z}


## {zoom, pan} that maps a graph-space bbox onto a target SCREEN rect (uniform
## scale, centered). This is the trick that makes a super-node's child content
## first appear exactly where the collapsed body was, so drilling in reads as one
## continuous zoom instead of a hard swap.
func _view_for_bbox_in_rect(graph_bbox: Rect2, screen_rect: Rect2) -> Dictionary:
	if graph_bbox.size.x <= 1.0 or graph_bbox.size.y <= 1.0 \
			or screen_rect.size.x <= 1.0 or screen_rect.size.y <= 1.0:
		return {"ok": false}
	var center := size * 0.5
	var z := clampf(minf(screen_rect.size.x / graph_bbox.size.x,
			screen_rect.size.y / graph_bbox.size.y), ZOOM_MIN, ZOOM_MAX)
	var gc := graph_bbox.position + graph_bbox.size * 0.5
	var rc := screen_rect.position + screen_rect.size * 0.5
	return {"ok": true, "zoom": z, "pan": rc - center - gc * z}


## Fit the active scope's contents to the viewport (used after a scope switch so
## the drill-in / pop-out lands on a comfortable, centered framing).
func fit_scope_to_view(pad_frac: float = 0.16) -> void:
	var fit := _scope_fit_view(active_scope_id, pad_frac)
	if not bool(fit.get("ok", false)):
		# Empty scope (e.g. hollow imported array) — neutral centered zoom.
		_zoom = clampf(1.0, ZOOM_MIN, ZOOM_MAX)
		_pan = Vector2.ZERO
		queue_redraw()
		return
	_animate_view(float(fit["zoom"]), fit["pan"] as Vector2)


## Center the view on one item at a moderate zoom (used popping back out onto the
## super-node the player just left).
func focus_on_item(item_id: String, target_zoom: float = 0.7) -> void:
	if model == null:
		return
	var it := model.get_item(item_id)
	if it.is_empty():
		return
	var c := Vector2(float(it.get("x", 0.0)) + float(it.get("width", 120.0)) * 0.5,
		float(it.get("y", 0.0)) + float(it.get("height", 90.0)) * 0.5)
	var tz := clampf(target_zoom, ZOOM_MIN, ZOOM_MAX)
	_animate_view(tz, -c * tz)


# ---------------------------------------------------------------------------
# Seamless scope transitions (continuous zoom-through). The VIEW still owns the
# scope swap (active_scope_id / _scope_trail); these helpers capture the framing
# on either side of the swap so the content grows out of / collapses into the
# super-node body rather than snapping.
# ---------------------------------------------------------------------------
var _view_tween: Tween = null
var _fade_tween: Tween = null
## Screen rect of the super-node body captured just before an enter swap.
var _enter_from_rect: Rect2 = Rect2()
## Screen bbox of the child content captured just before a pop swap.
var _pop_from_rect: Rect2 = Rect2()


## Called by the view BEFORE it swaps into `compound_id`'s child scope: remember
## where the collapsed body currently sits on screen.
func begin_enter_transition(compound_id: String) -> void:
	_enter_from_rect = Rect2()
	if model == null:
		return
	var it := model.get_item(compound_id)
	if it.is_empty():
		return
	var center := size * 0.5
	_enter_from_rect = Rect2(_item_screen_tl(it, center), _item_screen_size(it))


## Called by the view AFTER the swap: start the child content mapped onto the
## saved body rect, then tween to the comfortable fit. Falls back to a plain fit.
func finish_enter_transition() -> void:
	var fit := _scope_fit_view(active_scope_id)
	if not bool(fit.get("ok", false)):
		fit_scope_to_view()
		_play_content_fade()
		return
	var gb := _scope_content_graph_bbox(active_scope_id)
	var start := _view_for_bbox_in_rect(gb, _enter_from_rect)
	if bool(start.get("ok", false)):
		_zoom = float(start["zoom"])
		_pan = start["pan"] as Vector2
		queue_redraw()
	_animate_view(float(fit["zoom"]), fit["pan"] as Vector2, 0.26)
	_play_content_fade()


## Called by the view BEFORE it pops out of the active child scope: remember the
## child content's current on-screen bbox.
func begin_pop_transition() -> void:
	_pop_from_rect = _scope_content_screen_bbox(active_scope_id)


## Called by the view AFTER popping to the parent scope, with the compound we just
## left. Start framed so that compound's body fills where the child content was,
## then tween to a comfortable parent framing.
func finish_pop_transition(owner_compound_id: String) -> void:
	var target := _scope_fit_view(active_scope_id)
	var owner := model.get_item(owner_compound_id) if model != null else {}
	if not owner.is_empty():
		var center := size * 0.5
		# Where would the owner sit at the comfortable target framing? Map its
		# graph rect through the target transform, then set the START frame so
		# that rect currently overlaps the child bbox we just left.
		var tz: float = float(target.get("zoom", _zoom)) if bool(target.get("ok", false)) else _zoom
		var tp: Vector2 = target.get("pan", _pan) as Vector2 if bool(target.get("ok", false)) else _pan
		var og := Rect2(Vector2(float(owner.get("x", 0.0)), float(owner.get("y", 0.0))),
				Vector2(float(owner.get("width", 120.0)), float(owner.get("height", 90.0))))
		if _pop_from_rect.size.x > 1.0:
			var start := _view_for_bbox_in_rect(og, _pop_from_rect)
			if bool(start.get("ok", false)):
				_zoom = float(start["zoom"])
				_pan = start["pan"] as Vector2
				queue_redraw()
		if bool(target.get("ok", false)):
			_animate_view(tz, tp, 0.26)
		else:
			focus_on_item(owner_compound_id, clampf(_zoom, 0.5, 1.0))
	elif bool(target.get("ok", false)):
		_animate_view(float(target["zoom"]), target["pan"] as Vector2, 0.26)
	_play_content_fade()


## Subtle "materialize" fade on the whole canvas so the scope swap doesn't pop.
func _play_content_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	modulate.a = 0.55
	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_fade_tween.tween_property(self, "modulate:a", 1.0, 0.16)


## Smoothly tween _zoom + _pan to the given targets (short, so scope changes feel
## like a continuous zoom rather than a jump).
func _animate_view(target_zoom: float, target_pan: Vector2, dur: float = 0.22) -> void:
	if _view_tween != null and _view_tween.is_valid():
		_view_tween.kill()
	_view_tween = create_tween()
	_view_tween.set_parallel(true)
	_view_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_view_tween.tween_method(func(z: float): _zoom = z; queue_redraw(), _zoom, target_zoom, dur)
	_view_tween.tween_method(func(p: Vector2): _pan = p; queue_redraw(), _pan, target_pan, dur)


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
## Per-draw memo of bound_prop_id -> hidden_3d, so Site Plan can skip rings for
## twins hidden from 3D without a loader lookup per item per draw.
var _twin_hidden_cache: Dictionary = {}


func _visible_items() -> Array:
	if _draw_cache_active:
		return _cached_visible_items
	return _compute_visible_items()


func _compute_visible_items() -> Array:
	if model == null:
		return []
	var items: Array
	if model.has_method("get_items_in_scope"):
		items = model.get_items_in_scope(active_scope_id)
	else:
		items = []
		for item: Dictionary in model.items:
			if _scope_of_item(item) == active_scope_id:
				items.append(item)
	# Pinned PBIs are rendered in the fixed top bar, not in graph space.
	if _pbi_pinned_active():
		var filtered: Array = []
		for it: Dictionary in items:
			if str(it.get("type", "")) == "pbi":
				continue
			filtered.append(it)
		return filtered
	return items


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


# --- Destroy FX ------------------------------------------------------------
# A destroyed controller/battery is the tutorial's most teachable moment, so the
# blast is staged rather than a single puff: flash → fireball → shockwave →
# embers/debris → smoke, with a short camera shake. All timing/easing lives in
# static helpers so the selftest can pin the envelope without a viewport.

## Total lifetime of one burst (smoke outlasts the fire).
const FX_LIFETIME := 4.2
## While a burst is younger than this, the canvas redraws EVERY frame. The
## normal cadence is 20 fps (REDRAW_INTERVAL) — an explosion at 20 fps reads as
## a slideshow no matter how good the particle math is.
const FX_FULL_RATE_S := 2.2
const FX_SHAKE_S := 0.5
const FX_SHAKE_PX := 20.0
const FX_EMBERS := 36
const FX_DEBRIS := 12
## A second, tighter arc-flash a beat after the main blast — real electrical
## faults re-strike as trapped energy discharges a second time; it also just
## reads as "more" without stretching the whole sequence out.
const FX_CRACK_AT := 0.55
const FX_CRACK_S := 0.18
const FX_CRACK_SHAKE_S := 0.22
const FX_CRACK_SHAKE_PX := 10.0


## Normalized progress through a stage that runs [t0, t1], eased out. 0 before
## the stage opens, 1 once it has closed.
static func fx_stage(age: float, t0: float, t1: float) -> float:
	if age <= t0:
		return 0.0
	if age >= t1:
		return 1.0
	return (age - t0) / maxf(t1 - t0, 1e-6)


## Decaying multi-frequency shake offset (same technique as the vehicle camera
## shake in player.gd). Returns Vector2.ZERO once the shake window has passed.
## Sums the primary blast shake with a smaller pulse timed to the second
## arc-flash (FX_CRACK_AT) — two distinct hits read as a bigger event than one
## long decay, and the crack pulse is a separate window so it still lands even
## though it starts after the primary shake has finished.
static func fx_shake_offset(age: float) -> Vector2:
	var out := Vector2.ZERO
	if age >= 0.0 and age < FX_SHAKE_S:
		var decay := 1.0 - age / FX_SHAKE_S
		var amp := FX_SHAKE_PX * decay * decay
		out += Vector2(
			sin(age * 97.0) * 0.6 + sin(age * 43.0) * 0.4,
			sin(age * 71.0) * 0.6 + sin(age * 31.0) * 0.4) * amp
	var cage := age - FX_CRACK_AT
	if cage >= 0.0 and cage < FX_CRACK_SHAKE_S:
		var cdecay := 1.0 - cage / FX_CRACK_SHAKE_S
		var camp := FX_CRACK_SHAKE_PX * cdecay * cdecay
		out += Vector2(
			sin(cage * 131.0) * 0.6 + sin(cage * 59.0) * 0.4,
			sin(cage * 89.0) * 0.6 + sin(cage * 47.0) * 0.4) * camp
	return out


## Fireball color ramp: white-hot core cooling through gold and amber to a deep
## ember red, then to smoke.
static func fx_fire_color(t: float) -> Color:
	var u := clampf(t, 0.0, 1.0)
	if u < 0.25:
		return Color(1.0, 1.0, 0.95).lerp(UITheme.C_GOLD, u / 0.25)
	if u < 0.55:
		return UITheme.C_GOLD.lerp(UITheme.C_AMBER, (u - 0.25) / 0.30)
	if u < 0.80:
		return UITheme.C_AMBER.lerp(UITheme.C_ERROR, (u - 0.55) / 0.25)
	return UITheme.C_ERROR.lerp(Color(0.22, 0.20, 0.21), (u - 0.80) / 0.20)


func play_controller_destroy_fx(item_id: String, screen_center: Vector2) -> void:
	_destroy_fx.append({
		"item_id": item_id,
		"center": screen_center,
		"age": 0.0,
		# Per-burst seed so particle angles/speeds stay stable across redraws
		# (the canvas redraws on an interval, not every frame).
		"seed": int(abs(hash(item_id))) % 100003,
	})
	_needs_continuous_redraw = true
	_play_destroy_boom()
	queue_redraw()


const BOOM_SAMPLE_RATE := 22050
const BOOM_SECONDS := 1.2

var _boom_player: AudioStreamPlayer = null


## Explosion SFX, synthesized rather than shipped as an asset (no binary in the
## repo, nothing for the credits ledger). The DSP now lives in UiSfx so the
## destroy FX and the DANGER feedback tier are literally the same sound; this
## stays as the named entry point the FX envelope selftest pins.
static func build_boom_stream() -> AudioStreamWAV:
	return _UI_SFX.build_danger_stream(BOOM_SAMPLE_RATE, BOOM_SECONDS)


func _play_destroy_boom() -> void:
	# Offline selftests preload this script with no SceneTree / audio server.
	if not is_inside_tree():
		return
	# Prefer the shared voice pool so a warn chirp landing on top of a blast
	# doesn't cut it off; fall back to a local player if the autoload is absent
	# (harness scenes, tool runs).
	var sfx := _cached_autoload("/root/UiSound")
	if sfx != null:
		sfx.call("play_ui", _UI_SFX.DANGER)
		return
	if _boom_player == null or not is_instance_valid(_boom_player):
		_boom_player = AudioStreamPlayer.new()
		_boom_player.name = "DestroyBoom"
		_boom_player.stream = build_boom_stream()
		_boom_player.volume_db = -6.0
		add_child(_boom_player)
	_boom_player.play()


## Tiered UI feedback from the canvas (see UiSfx). Resolved defensively — a
## bare autoload identifier would break offline selftests that preload this.
func _play_ui_sfx(kind: String, min_gap_ms: int = 0) -> void:
	if not is_inside_tree():
		return
	var sfx := _cached_autoload("/root/UiSound")
	if sfx != null:
		sfx.call("play_ui", kind, min_gap_ms)


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

	# Pinned PBI bar: near the output dot → wire drag; elsewhere on the pill →
	# select the PBI (so the inspector shows it). Pills are fixed, never dragged.
	if _pbi_pinned_active():
		for iid in _pbi_pill_rects:
			var pill: Dictionary = _pbi_pill_rects[iid] as Dictionary
			var prect: Rect2 = pill.get("rect", Rect2()) as Rect2
			if not prect.has_point(screen_pos):
				continue
			var pport: Dictionary = pill.get("port", {}) as Dictionary
			var dot: Vector2 = pport.get("pos", Vector2.ZERO) as Vector2
			if screen_pos.distance_to(dot) <= _port_grab_radius():
				_start_wire_drag(pport)
				_touch_interaction = "wire"
			else:
				_select_item(str(iid))
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
		# Watershed catchments: select for inspector only — never drag the basin.
		if _is_watershed_item(hit):
			_select_item(str(hit.get("id", "")))
			return
		# Site Plan magnifiers are always interactive (drag / wire ports).
		# Elevation chips-off: don't chip-drag placed items (3D spatial edit owns them).
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_chips \
				and GraphSiteLayout.has_site_coords(hit):
			# Prefer bound 3D prop drag when ray pick missed (section clip / tiny AABB).
			if _try_elev_bound_prop_drag(hit, screen_pos):
				return
			_select_item(str(hit.get("id", "")))
			return
		var port_phys := _port_at_screen(screen_pos, "", "", _port_grab_radius())
		# Elevation: ports are opt-in wiring (Alt) — never steal turbine/prop moves.
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and not port_phys.is_empty() \
				and not (Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META)):
			if _try_elev_bound_prop_drag(hit, screen_pos):
				return
			_begin_item_press(screen_pos, hit)
			return
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
		# Elevation: Alt = wire / hub rotate; plain click must not own the CT.
		if view_mode == GraphSiteLayout.VIEW_ELEVATION \
				and not (Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META)):
			port = {}
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


## Elevation chips-off: start a 3D prop drag from the graph item's bound twin
## when the section raycast missed (common for small hydroturbine AABBs).
func _try_elev_bound_prop_drag(item: Dictionary, screen_pos: Vector2) -> bool:
	if spatial_edit == null or item.is_empty():
		return false
	if view_mode != GraphSiteLayout.VIEW_ELEVATION:
		return false
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	if prop_id.is_empty():
		return false
	# Must be near the item's elev projection so random clicks don't steal.
	var pad := _elev_port_pad_rect(item, Vector2.ZERO, Vector2.ZERO)
	var hit_r := maxf(pad.size.x, pad.size.y) * 0.5 + 28.0
	if pad.get_center().distance_to(screen_pos) > hit_r:
		return false
	if spatial_edit.has_method("begin_prop_drag_id") \
			and bool(spatial_edit.call("begin_prop_drag_id", prop_id, screen_pos)):
		_touch_interaction = "spatial"
		accept_event()
		queue_redraw()
		return true
	return false


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
	_item_drag_cursor_site_start = Vector2.ZERO
	_item_drag_cursor_elev_start = {}
	if _phys_camera_projection_active():
		if view_mode == GraphSiteLayout.VIEW_SITE \
				and soi_preview_service.has_method("canvas_to_site_ground"):
			var w0: Variant = soi_preview_service.call("canvas_to_site_ground", screen_pos)
			if w0 is Vector2:
				_item_drag_cursor_site_start = w0 as Vector2
		elif view_mode == GraphSiteLayout.VIEW_ELEVATION \
				and soi_preview_service.has_method("canvas_to_elevation_hit"):
			var e0: Variant = soi_preview_service.call(
					"canvas_to_elevation_hit", screen_pos, elevation_heading_rad)
			if e0 is Dictionary:
				_item_drag_cursor_elev_start = e0 as Dictionary
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
			if view_mode == GraphSiteLayout.VIEW_SITE:
				site_background_clicked.emit(screen_pos)
			_select_item("")


# Item drag move
func _on_item_drag_move(screen_pos: Vector2) -> void:
	if model == null or _item_drag_id.is_empty():
		return
	# Watershed basins are terrain-derived — never move with the chip.
	if model != null:
		var drag_it := model.get_item(_item_drag_id)
		if _is_watershed_item(drag_it):
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
	# Orbited Site: convert the pointer to a world point on the SoI ground plane
	# via the preview camera so nodes drop under the cursor at any tilt.
	var use_cam: bool = _phys_camera_projection_active() \
			and soi_preview_service != null \
			and soi_preview_service.has_method("canvas_to_site_ground")
	var cursor_site: Vector2 = Vector2.INF
	if use_cam:
		var w: Variant = soi_preview_service.call("canvas_to_site_ground", screen_pos)
		if w is Vector2:
			cursor_site = w as Vector2
	for iid: String in _item_drag_ids:
		var start_pos: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var new_xz: Vector2
		if use_cam and cursor_site.x != INF:
			# Camera path: seat the pointer exactly, preserving per-item offset.
			var off := Vector2.ZERO
			if not is_nan(start_pos.x):
				off = start_pos - _item_drag_cursor_site_start
			new_xz = cursor_site + off
		elif is_nan(start_pos.x):
			# Dropping from unplaced tray onto the disc.
			new_xz = GraphSiteLayout.screen_to_site_m(screen_pos, disc_o, _zoom)
		else:
			new_xz = start_pos + delta_m
		new_xz = GraphSiteLayout.clamp_to_soi(new_xz, r_m)
		model.update_item(iid, {"site_x_m": new_xz.x, "site_z_m": new_xz.y})
		# Live-preview the bound 3D twin under the magnifier (release still heals).
		if site_drag_sync_prop.is_valid():
			site_drag_sync_prop.call(iid, new_xz)
	queue_redraw()


func _on_elevation_item_drag_move(screen_pos: Vector2, delta_px: Vector2) -> void:
	# Horizontal → along-section site metres; vertical → elevation_m (screen-up = +Y).
	# When the physical camera is the projection authority, ray-cast the pointer
	# onto the vertical section plane so an orbited view still tracks the cursor.
	var s := GraphSiteLayout.px_per_m(_zoom)
	var ex := _elev_exaggeration_draw()
	var r_m := _soi_radius_m()
	var disc_o := _disc_origin_screen()
	var use_cam: bool = _phys_camera_projection_active() \
			and soi_preview_service != null \
			and soi_preview_service.has_method("canvas_to_elevation_hit")
	var cursor_hit: Dictionary = {}
	if use_cam:
		var w: Variant = soi_preview_service.call(
				"canvas_to_elevation_hit", screen_pos, elevation_heading_rad)
		if w is Dictionary:
			cursor_hit = w as Dictionary
	for iid: String in _item_drag_ids:
		var start_xz: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var site: Vector2
		var elev_m: float
		if use_cam and not cursor_hit.is_empty():
			var cur_site := Vector2(
					float(cursor_hit.get("site_x_m", 0.0)),
					float(cursor_hit.get("site_z_m", 0.0)))
			var cur_elev := float(cursor_hit.get("elevation_m", _elevation_datum_m()))
			if is_nan(start_xz.x) or _item_drag_cursor_elev_start.is_empty():
				site = cur_site
				elev_m = cur_elev
			else:
				var start_site0 := Vector2(
						float(_item_drag_cursor_elev_start.get("site_x_m", 0.0)),
						float(_item_drag_cursor_elev_start.get("site_z_m", 0.0)))
				var start_elev0 := float(_item_drag_cursor_elev_start.get(
						"elevation_m", _elevation_datum_m()))
				site = start_xz + (cur_site - start_site0)
				# Preserve the item's cross-section depth (ray hits the center plane).
				var proj_start := GraphSiteLayout.project_onto_section(
						start_xz, elevation_heading_rad)
				var proj_new := GraphSiteLayout.project_onto_section(
						site, elevation_heading_rad)
				site = GraphSiteLayout.section_to_site(
						proj_new.x, proj_start.y, elevation_heading_rad)
				var start_elev: float = float(
						_item_drag_start_elev.get(iid, _elevation_datum_m()))
				elev_m = start_elev + (cur_elev - start_elev0)
		elif is_nan(start_xz.x):
			# Dropping from unplaced tray — seat under the pointer (anchored flat).
			_ensure_elev_anchor()
			var vc := size * 0.5
			var along_m := _elev_anchor_along_m + (screen_pos.x - vc.x) / s
			elev_m = get_elev_anchor_elev_m() - (screen_pos.y - vc.y) / (s * ex)
			site = GraphSiteLayout.section_to_site(along_m, 0.0, elevation_heading_rad)
		else:
			var proj0 := GraphSiteLayout.project_onto_section(start_xz, elevation_heading_rad)
			var along2 := proj0.x + delta_px.x / s
			var start_elev2: float = float(
					_item_drag_start_elev.get(iid, _elevation_datum_m()))
			elev_m = start_elev2 - delta_px.y / (s * ex)
			site = GraphSiteLayout.section_to_site(along2, proj0.y, elevation_heading_rad)
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
	# Site Plan: all magnifiers are circular. Elevation keeps type-based shapes.
	if view_mode == GraphSiteLayout.VIEW_SITE:
		return true
	if _is_physical_view():
		return GraphSiteLayout.uses_circular_plan_chip(item, view_mode)
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
	var d_lvl_raw := float(d_specs.get("level", 0.0))
	var t_lvl_raw := float(t_specs.get("level", 0.0))
	var d_lvl := clampf(d_lvl_raw, 0.0, 1.0)
	var t_lvl := clampf(t_lvl_raw, 0.0, 1.0)
	var new_cap := d_cap + t_cap
	var new_lvl := (d_cap * d_lvl + t_cap * t_lvl) / new_cap if new_cap > 0.001 else 0.0
	var target_id := str(target.get("id", ""))
	var unit := str(t_specs.get("capacity_unit", ResourceKinds.default_unit(t_kind)))
	# Infinity / deficit flags OR across both parents — do not collapse an
	# unlimited tank into a finite sum of nominal capacity_qty alone.
	t_specs["unlimited_capacity"] = d_unlim or t_unlim
	t_specs["allow_negative"] = d_neg or t_neg
	if bool(t_specs["allow_negative"]):
		# Preserve absolute stock (may be negative) across the merge; capacity
		# is only a display/scale unit for deficit tanks.
		var d_stock := d_lvl_raw * maxf(d_cap, 0.001)
		var t_stock := t_lvl_raw * maxf(t_cap, 0.001)
		var scale_cap := maxf(new_cap, 0.001)
		if bool(t_specs["unlimited_capacity"]):
			scale_cap = maxf(maxf(d_cap, t_cap), 100.0)
		t_specs["capacity_qty"] = scale_cap
		t_specs["level"] = (d_stock + t_stock) / scale_cap
	elif bool(t_specs["unlimited_capacity"]):
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
	# Elevation chips-off: skip placed items so picks fall through to 3D spatial
	# edit / terrain. Site Plan magnifiers are always pickable.
	var skip_placed := view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_chips
	# Iterate in reverse so topmost (last drawn) is hit first
	var vis := _visible_items()
	for i in range(vis.size() - 1, -1, -1):
		var item: Dictionary = vis[i]
		if skip_placed and GraphSiteLayout.has_site_coords(item):
			continue
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
	# Elevation: match drawn port dots (screen-space cap). Uncapped 9×zoom
	# becomes invisible megapixel grabs that block node/terrain picks.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		var s := GraphSiteLayout.px_per_m(_zoom)
		return clampf(0.35 * s, ELEV_PORT_GRAB_MIN_PX, ELEV_PORT_GRAB_MAX_PX)
	var base := maxf(10.0, 9.0 * _zoom)
	if _touch_input_active() or DisplayServer.is_touchscreen_available():
		return maxf(base, TOUCH_PORT_GRAB_MIN)
	return base


func _port_hit_radius() -> float:
	return _port_grab_radius()


func _wire_snap_radius() -> float:
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		return _port_grab_radius() + 4.0
	var base := maxf(SNAP_RADIUS_PX, _port_grab_radius() + 6.0)
	if _touch_input_active() or DisplayServer.is_touchscreen_available():
		return maxf(base, TOUCH_SNAP_RADIUS_MIN)
	return base


func _wheel_zoom_factor() -> float:
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		return ELEV_WHEEL_ZOOM
	return 1.08


## Flip a travel direction into the target endpoint's OUTWARD control tangent
## (the convention `_wire_bezier_controls` wants — see its header). Only for
## endpoints with no real port: a wire heading `dir` should have its far
## control point pulled back along `-dir`, toward the source. Real ports pass
## their own outward normal straight through and must NOT be routed here.
func _incoming_tangent(travel_dir: Vector2) -> Vector2:
	return -travel_dir


## True when a DC wire belongs to a COMPLETE circuit — a controller with both
## PV legs wired and a battery bank attached. `hint` is live_power_hint, filled
## by SystemGraphView._publish_live_circuits from the throttle tick's existing
## work, so this costs a dictionary lookup rather than a graph traversal.
##
## The old test was "is either endpoint a panel, and is the ARRAY producing?" —
## with array output computed from insolation, entirely independent of wiring.
## A single wire dangling off an unconnected panel therefore animated and
## reported the whole array's wattage. `legacy_ok` keeps the virtual
## solar_bridge chain (which has no real controller) animating as before.
static func dc_circuit_live(hint: Dictionary, src_id: String, tgt_id: String,
		legacy_ok: bool = false) -> bool:
	var circuits: Dictionary = hint.get("circuits", {}) as Dictionary
	if circuits.is_empty():
		# Nothing published yet (no real controller in the graph, or the first
		# frames after a load): fall back to the old permissive behaviour so
		# freeplay and the virtual chain are unchanged.
		return true
	if circuits.has(src_id) or circuits.has(tgt_id):
		return true
	var member_of: Dictionary = hint.get("circuit_of", {}) as Dictionary
	if member_of.has(src_id) or member_of.has(tgt_id):
		return true
	return legacy_ok


## Live voltage on a DC wire: the array's string Voc on the PV side of a
## controller, the bank's bus voltage on the battery side. 0 when unknown.
static func dc_circuit_volts(hint: Dictionary, src_id: String, tgt_id: String,
		pv_side: bool) -> float:
	var circuits: Dictionary = hint.get("circuits", {}) as Dictionary
	if circuits.is_empty():
		return 0.0
	var member_of: Dictionary = hint.get("circuit_of", {}) as Dictionary
	var cid := ""
	for candidate in [src_id, tgt_id]:
		if circuits.has(candidate):
			cid = str(candidate)
			break
		if member_of.has(candidate):
			cid = str(member_of[candidate])
			break
	if cid.is_empty() or not circuits.has(cid):
		return 0.0
	var c: Dictionary = circuits[cid]
	return float(c.get("array_voc", 0.0)) if pv_side else float(c.get("bus_v", 0.0))


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


## Cubic control points for a wire. BOTH tangents are "the direction from that
## endpoint toward its own control point", i.e. the port's OUTWARD normal —
## the wire then leaves and arrives through open canvas instead of cutting
## across the node body.
##
## `to_tang_out` used to be handed the port's INWARD normal (via
## `_incoming_tangent`), which parked c2 inside the target node: two ports on
## the same edge (series-wiring two panels side by side) drew a flat "~" that
## disappeared behind the nodes instead of the expected U looping below them.
## Direction-derived callers (no real port) pass `-(to - from).normalized()`,
## which is already outward-from-the-target in that sense.
func _wire_bezier_controls(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_out: Vector2, curve_tension: float = 1.0) -> Dictionary:
	if from.is_equal_approx(to):
		return {"c1": from, "c2": to}

	var spread := _wire_spread(from, to) * curve_tension

	# The blend only nudges a control point back toward the far endpoint when the
	# port faces away from it, so a backwards layout eases instead of looping
	# wildly. Ports that already face each other (the common vertical case) are
	# left exactly as authored, and same-edge pairs keep most of their outward
	# throw — that throw IS the U.
	var dir1 := from.direction_to(to)
	var t1 := from_tang
	var dot1 := t1.dot(dir1)
	if dot1 < 0.3:
		var blend := clampf((0.3 - dot1) / 1.3, 0.0, 1.0)
		t1 = t1.lerp(dir1, blend).normalized()

	var dir2 := to.direction_to(from)
	var t2 := to_tang_out
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


## Screen-px corner radius for drawing. Physical views clamp so tiny close chips
## don't bloom into giant loops (Freeform keeps the full zoomed radius).
func _conn_corner_radius_px(conn: Dictionary, endpoint_dist_px: float = INF) -> float:
	var r := _conn_corner_radius_graph(conn) * _zoom
	if not _is_physical_view():
		return r
	var cap := PHYS_WIRE_CORNER_MAX_PX
	if is_finite(endpoint_dist_px) and endpoint_dist_px > 1.0:
		cap = minf(cap, endpoint_dist_px * 0.22)
	return clampf(r, 2.0, maxf(cap, 2.0))


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
	# Per-action confirmation that the wire landed. Quiet + rate-limited so a
	# fast wiring session doesn't machine-gun; a mismatched-kind drop gets the
	# warn tier instead, since it connected but won't carry anything.
	_play_ui_sfx(_UI_SFX.WARN if type_mismatch else _UI_SFX.CONNECT, 90)


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
## node pre-wired to the source port, instead of discarding the drag.
## Defaults to allow_negative (deficit-capable) so stock stays visible and
## downstream/upstream never hard-block — toggle ∞ capacity in the inspector
## if you want a conceptual unlimited tank instead.
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
		"level": 0.0,
		"unlimited_capacity": false,
		"allow_negative": true,
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
	# Elev chips-off: hit positions must match compact port pads (drawn path).
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_chips \
			and GraphSiteLayout.has_site_coords(item):
		var pad := _elev_port_pad_rect(item, tl, sz)
		tl = pad.position
		sz = pad.size
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
	# Hidden ambient documentary ports are not grabbable either — otherwise an
	# invisible dot in the middle of a panel's top edge hijacks the drag that
	# was meant to move the node.
	var visible_all: Array = []
	for h0: Dictionary in all:
		var hid0 := str(h0.get("handle_id", ""))
		if is_ambient_doc_handle(itype, hid0) and not _ambient_doc_handle_shown(item, hid0):
			continue
		visible_all.append(h0)
	all = visible_all
	# Array compounds expose exactly the two bus ports from _resolved_handles;
	# they must all stay interactive (the generic "compound" primary filter would
	# otherwise drop them since their ids are "positive"/"negative").
	if itype == "compound" \
			and str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) == "array":
		return all
	# Generic super-node: all promoted ports are interactive (their ids like
	# "in_positive_1" are not in _PRIMARY_HANDLES, so the filter would wrongly
	# drop them). Mirror the draw path — every own handle is wireable.
	if itype == "compound" \
			and str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) == "" \
			and not (item.get("handles", []) as Array).is_empty():
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
	# Elevation: ports are opt-in via menu. Site Plan magnifiers always expose
	# rim ports so metro 2D wires can connect.
	if _is_physical_view():
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_ports:
			return {}
		if view_mode == GraphSiteLayout.VIEW_SITE and not site_show_ports:
			return {}
	# Ambient-port visibility gates grabbability too — refresh once per query,
	# not once per node (see _refresh_ambient_wired_ports).
	_refresh_ambient_wired_ports()
	var center    := size * 0.5
	var best_dist := radius
	var best:       Dictionary = {}
	var water_drag := _wire_src_polarity == "resource" \
			and ResourceKinds.normalize_kind(_wire_src_resource_kind) == "water"
	for item: Dictionary in _visible_items():
		for h: Dictionary in _get_interactive_handle_infos(item, center):
			if h["item_id"] == skip_item and h["handle_id"] == skip_handle:
				continue
			var d := (h["pos"] as Vector2).distance_to(screen_pos)
			# Prefer water resource ports over nearby DC +/- when dragging water.
			if water_drag:
				var hk := str(h.get("resource_kind", ""))
				var hp := str(h.get("polarity", ""))
				if hp == "resource" and (hk.is_empty() or hk == "water"):
					d *= 0.72
				elif hp in ["positive", "negative", "smart_battery"]:
					d += radius * 0.65
			if d < best_dist:
				best_dist = d
				best = h
	# Pinned PBI pills — their output port is wireable straight off the top bar.
	if _pbi_pinned_active():
		for iid in _pbi_pill_rects:
			var pill: Dictionary = _pbi_pill_rects[iid] as Dictionary
			var pport: Dictionary = pill.get("port", {}) as Dictionary
			if str(pport.get("item_id", "")) == skip_item \
					and str(pport.get("handle_id", "")) == skip_handle:
				continue
			var pd := (pport.get("pos", Vector2.ZERO) as Vector2).distance_to(screen_pos)
			# Grab if near the port dot OR anywhere over the pill rect.
			if (pill.get("rect", Rect2()) as Rect2).has_point(screen_pos):
				pd = minf(pd, radius * 0.5)
			if pd < best_dist:
				best_dist = pd
				best = pport
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
	# Series PV / DC strings: panel+ → next panel− (and the reverse drag).
	if (src == "positive" and tgt == "negative") \
			or (src == "negative" and tgt == "positive"):
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
	var to_tang_out: Vector2

	if not _wire_snap.is_empty():
		# Outward normal of the snapped port — the preview must curve in the way
		# the committed wire will (see _wire_bezier_controls).
		to_tang_out = _wire_snap.get("tangent", Vector2.RIGHT) as Vector2
		to_pos = _wire_snap.get("pos", Vector2.ZERO) as Vector2
	else:
		to_pos = _wire_cursor_pos
		to_tang_out = (_wire_src_pos - _wire_cursor_pos).normalized()

	var ctrl := _wire_bezier_controls(_wire_src_pos, _wire_src_tangent, to_pos, to_tang_out)
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
	var pulse_r := 9.0 * _zoom
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		pulse_r = _port_grab_radius()
	draw_circle(_wire_src_pos, pulse_r, Color(col.r, col.g, col.b, 0.25))

	# Snap-target highlight
	if not _wire_snap.is_empty():
		var snap_pos := _wire_snap.get("pos", Vector2.ZERO) as Vector2
		var ring_col := C_RED
		if _wire_snap_valid:
			ring_col = UITheme.C_WARN if snap_kind_override else C_GREEN
		var snap_r := pulse_r
		draw_circle(snap_pos, snap_r + 1.0, Color(ring_col.r, ring_col.g, ring_col.b, 0.25))
		draw_circle(snap_pos, snap_r, ring_col, false)
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
	if it.is_empty():
		return false
	if _is_load_group_item(it):
		if _ac_shed_active:
			return false
		return _load_group_draw_w(it) > WIRE_DEAD_W
	var ty: String = str(it.get("type", ""))
	if _ac_shed_active:
		if ty in ["appliance", "acload", "processor", "acoutlet", "acbreaker"]:
			return false
	# Authority = GraphAcLoad (processors draw only while RUNNING / batch > 0).
	var tree := get_tree()
	if tree != null and model != null:
		return GraphAcLoad.item_draw_watts(model, it, tree, _find_sim_load_host()) > WIRE_DEAD_W
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	if ty == "processor":
		if it.has("batch_active_watts"):
			return float(it.get("batch_active_watts", 0.0)) > WIRE_DEAD_W
		return str(sp.get("node_state", "")) == GraphNodeState.RUNNING
	var st: String = str(sp.get("current_state", "")).to_lower()
	var is_on_v: Variant = it.get("is_on", null)
	if is_on_v != null and not bool(is_on_v):
		return false
	if st == "off":
		return false
	if st == "on":
		var w: float = float(sp.get("avg_watts", sp.get("watts", sp.get("max_watts", 0.0))))
		return w > WIRE_DEAD_W
	var req := str(sp.get("requested_state", "")).to_lower()
	if req == "off":
		return false
	if req == "on":
		var w2: float = float(sp.get("avg_watts", sp.get("watts", sp.get("max_watts", 0.0))))
		return w2 > WIRE_DEAD_W
	return false


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

	# Inverter / AC bus → loads: thickness tracks ACTUAL draw (GraphAcLoad),
	# not nameplate watts. Blocked / idle / starved / off → floor + inactive.
	if pol == "ac" or pol == "load" or (st == "controller" and _is_ac_sink_type(tt)) \
			or (tt == "controller" and _is_ac_sink_type(st)):
		var tree := get_tree()
		var actual_w := 0.0
		if tree != null:
			actual_w = GraphAcLoad.connection_delivered_watts(
					model, conn, tree, _find_sim_load_host())
		# Fallback when delivered-side BFS can't see a controller (island / hostless):
		# use the sink item's live draw if one endpoint is a load.
		if actual_w <= WIRE_DEAD_W:
			var load_item: Dictionary = {}
			if _is_ac_sink_type(tt) or _is_load_group_item(titem):
				load_item = titem
			elif _is_ac_sink_type(st) or _is_load_group_item(sitem):
				load_item = sitem
			if not load_item.is_empty():
				if tree != null:
					actual_w = GraphAcLoad.item_draw_watts(
							model, load_item, tree, _find_sim_load_host())
				elif _is_load_group_item(load_item):
					actual_w = _load_group_draw_w(load_item)
				elif load_item.has("batch_active_watts"):
					actual_w = float(load_item.get("batch_active_watts", 0.0))
				elif str((load_item.get("specs", {}) as Dictionary).get("node_state", "")) \
						== GraphNodeState.RUNNING:
					var lsp: Dictionary = load_item.get("specs", {}) as Dictionary
					actual_w = float(lsp.get("avg_watts", lsp.get("watts", 0.0)))
		if actual_w <= WIRE_DEAD_W:
			return {"watts": WIRE_FLOW_FLOOR, "reverse": false, "active": false}
		var reverse_ac: bool = (tt == "controller")
		return {"watts": maxf(WIRE_FLOW_FLOOR, actual_w), "reverse": reverse_ac, "active": true}

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
	# AND this wire belongs to a completed circuit.
	if sid == "virtual_solar_array" or tid == "virtual_solar_array" or st == "panel" or tt == "panel":
		var producing: bool = solar_w > WIRE_DEAD_W and dc_circuit_live(
			live_power_hint, sid, tid, sid == "virtual_solar_array" or tid == "virtual_solar_array")
		var w_pv: float = maxf(solar_w, 5.0)
		if w_pv < 20.0:
			w_pv = 5.0 + solar_w * 0.15
		if not producing:
			w_pv = 0.0
		return {"watts": w_pv, "reverse": false, "active": producing,
			"volts": dc_circuit_volts(live_power_hint, sid, tid, true)}

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
		var virtual_pair := sid.begins_with("virtual_") or tid.begins_with("virtual_")
		var active_b: bool = ((w_b > WIRE_DEAD_W * 2.0) or solar_w > WIRE_DEAD_W) \
			and dc_circuit_live(live_power_hint, sid, tid, virtual_pair)
		if not active_b:
			w_b = 0.0
		return {"watts": w_b, "reverse": rev, "active": active_b,
			"volts": dc_circuit_volts(live_power_hint, sid, tid, false)}

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
	_wire_lod_simplify = visible.size() > WIRE_LOD_HIGH_COUNT \
			or _zoom < WIRE_LOD_ZOOM_CUTOFF \
			or _zoom > WIRE_LOD_ZOOM_HIGH \
			or (view_mode == GraphSiteLayout.VIEW_ELEVATION and visible.size() > 24) \
			or _high_speed_lod
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
	# Physical views (Site Plan / Elevation): an unplaced endpoint sits in the
	# tray, so a full wire to it sweeps across the whole map as spaghetti.
	# Suppress those wires — spatial views show conduit routes between PLACED
	# gear; logical wiring lives in Freeform.
	if _is_physical_view():
		var s_it := model.get_item(sid)
		var t_it := model.get_item(tid)
		if (not s_it.is_empty() and not GraphSiteLayout.has_site_coords(s_it)) \
				or (not t_it.is_empty() and not GraphSiteLayout.has_site_coords(t_it)):
			return
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
	if bool(conn.get("reverse_polarity", false)):
		# Backwards + to −: red, and never animated (it carries nothing).
		base_col = Color(1.0, 0.20, 0.20, 0.95)
		flow_active = false
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

	var tgt_tang_out := (tgt.get("tangent", Vector2.RIGHT) as Vector2)
	var wps: Array = _waypoints_screen(conn, center)
	var style: String = _effective_line_style(conn)
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
	tgt_tang_out = (tgt.get("tangent", Vector2.RIGHT) as Vector2)

	# Connection style overrides
	var c_color = str(conn.get("color_override", ""))
	if not c_color.is_empty():
		col = Color(c_color)
	var c_thick = float(conn.get("thickness_override", 0.0))
	if c_thick > 0.1:
		width = c_thick * _zoom
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		width = minf(width, ELEV_WIRE_MAX_PX)
	# Physical views: shrink bezier/metro handles so close chips stay near-straight.
	if _is_physical_view():
		var link_len := src_pos.distance_to(tgt_pos)
		var max_tang := clampf(link_len * 0.18, 4.0, 28.0)
		if src_t.length() * 40.0 * _zoom > max_tang:
			src_t = src_t.normalized()
			src["tangent"] = src_t
		if tgt_tang_out.length() * 40.0 * _zoom > max_tang:
			tgt_tang_out = tgt_tang_out.normalized()
		# Stamp a transient draw-only corner clamp used by metro/ortho helpers.
		conn = conn.duplicate()
		conn["_draw_corner_px"] = _conn_corner_radius_px(conn, link_len)
	var sankey_scale = bool(conn.get("sankey_scale", true))

	if is_resource_wire:
		# Radiant (sunlight) links are always dashed/glowing regardless of
		# line_style — they visualize an ambient, non-blocking connection
		# rather than a piped one (Phase 3 solar PBI).
		# Ambient radiant links (sunlight / wind) are always dashed/glowing
		# regardless of line_style — they visualize optional non-blocking
		# environment links (see atmosphere_pbi.gd / solar_pbi_selftest.gd).
		# Elevation CT: suppress radiant/schematic resource wires before they
		# paint gold diagonals across the slice (sunlight PBI looked like a streak).
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and soi_live_preview \
				and not elev_show_schematic_wires:
			if ConduitKinds.is_direct_intake_connection(conn, model):
				_draw_direct_intake_stub(src_pos, tgt_pos, col, width, flowing, is_sel)
			elif elev_show_projected_pipes \
					and _try_draw_elev_conduit_projection(conn, col, width, flowing, res_rate, res_kind):
				pass
			return
		if res_kind == "sunlight" or res_kind == "wind":
			# Honor the selected wire style (Wire ▾): metro/orthogonal radiant
			# links route like every other wire; the dashed-glow bezier remains
			# the bezier-style look (ambient/optional semantics stay in color +
			# glow, not in a style exemption).
			if style == "metro":
				_draw_wire_metro_path([src_pos] + wps + [tgt_pos],
					[src_t, tgt_tang_out], col, width, flowing, res_rate, false, conn)
			elif style == "orthogonal":
				_draw_resource_wire_orthogonal_path(
					[src_pos] + wps + [tgt_pos], [src_t, tgt_tang_out],
					col, width, flowing, false, curve_t,
					res_rate, res_kind, sankey_scale)
			elif wps.is_empty():
				_draw_radiant_wire_bezier(
					src_pos, src_t, tgt_pos, tgt_tang_out, col, width, flowing, curve_t, res_rate, res_kind)
			else:
				_draw_radiant_wire_path(
					[src_pos] + wps + [tgt_pos], [src_t, tgt_tang_out],
					col, width, flowing, curve_t, res_rate, res_kind)
			# Always show the flux label when there's meaningful flux (educational),
			# even in Build mode — radiant links are documentary.
			if res_rate > ResourceEdgeVis.FLOW_DEAD_RATE and _zoom >= WIRE_LABEL_MIN_ZOOM:
				_draw_flow_label(src_pos, tgt_pos, wps, res_rate, true, res_kind, col)
			_draw_connection_waypoint_handles(conn, center)
			return
		# Site Plan: prefer_3d / none → rely on world conduits; metro → 2D overlay.
		if view_mode == GraphSiteLayout.VIEW_SITE and soi_live_preview \
				and not _site_draws_schematic_wires():
			return
		# Elevation 3D: prefer world conduits + flow glow; optional projected
		# polyline from ConduitManager samples (never freeform waypoints).
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and soi_live_preview:
			if ConduitKinds.is_direct_intake_connection(conn, model):
				_draw_direct_intake_stub(src_pos, tgt_pos, col, width, flowing, is_sel)
				return
			if _try_draw_elev_conduit_projection(conn, col, width, flowing, res_rate, res_kind):
				return
			if not elev_show_schematic_wires:
				return
		# Elevation (2D-only or schematic on): culvert barrels as straight chords.
		if view_mode == GraphSiteLayout.VIEW_ELEVATION \
				and ConduitKinds.uses_culvert_kit(
					ConduitKinds.derive_type_for_connection(conn)):
			_draw_elevation_culvert_wire_straight(src_pos, tgt_pos, col, width, flowing, res_rate)
			if flowing and _zoom >= WIRE_LABEL_MIN_ZOOM:
				_draw_flow_label(src_pos, tgt_pos, [], res_rate, true, res_kind, col)
			return
		# Siphon direct intake: short stub at pond edge (no full conduit spaghetti).
		if ConduitKinds.is_direct_intake_connection(conn, model):
			_draw_direct_intake_stub(src_pos, tgt_pos, col, width, flowing, is_sel)
			_draw_connection_waypoint_handles(conn, center)
			return
		if style == "metro":
			var pts_r: Array = [src_pos] + wps + [tgt_pos]
			_draw_wire_metro_path(pts_r, [src_t, tgt_tang_out], col, width, flowing, res_rate, reverse, conn)
		elif style == "orthogonal":
			var pts_r: Array = [src_pos] + wps + [tgt_pos]
			_draw_resource_wire_orthogonal_path(
				pts_r, [src_t, tgt_tang_out], col, width, flowing, reverse, curve_t,
				res_rate, res_kind, sankey_scale)
		elif wps.is_empty():
			_draw_resource_wire_bezier(
				src_pos, src_t, tgt_pos, tgt_tang_out, col, width, flowing, reverse, curve_t,
				res_rate, res_kind, sankey_scale)
		else:
			_draw_resource_wire_path(
				[src_pos] + wps + [tgt_pos], [src_t, tgt_tang_out],
				col, width, flowing, reverse, curve_t, res_rate, res_kind, sankey_scale)
		if flowing and _zoom >= WIRE_LABEL_MIN_ZOOM:
			_draw_flow_label(src_pos, tgt_pos, wps, res_rate, true, res_kind, col)
		_draw_connection_waypoint_handles(conn, center)
		return
	# Site Plan: prefer_3d / none → world conduits only (no schematic overlay).
	if view_mode == GraphSiteLayout.VIEW_SITE and soi_live_preview \
			and not _site_draws_schematic_wires():
		return
	# Elevation 3D: non-resource wires follow the same 3D / projected authority.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and soi_live_preview:
		if _try_draw_elev_conduit_projection(conn, col, width, flowing, flow_watts, ""):
			return
		if not elev_show_schematic_wires:
			return
	if style == "metro":
		var pts: Array = [src_pos] + wps + [tgt_pos]
		_draw_wire_metro_path(pts, [src_t, tgt_tang_out], col, width, flowing, flow_watts, reverse, conn)
	elif style == "orthogonal":
		var pts: Array = [src_pos] + wps + [tgt_pos]
		_draw_wire_orthogonal_path(
			pts, [src_t, tgt_tang_out], col, width, flowing, flow_watts, reverse, conn)
	elif wps.is_empty():
		_draw_wire_bezier(src_pos, src_t, tgt_pos, tgt_tang_out,
			col, width, flowing, flow_watts, reverse, curve_t)
	else:
		_draw_wire_path(
			[src_pos] + wps + [tgt_pos],
			[src_t, tgt_tang_out],
			col, width, flowing, flow_watts, reverse, curve_t)
	if flowing and _zoom >= WIRE_LABEL_MIN_ZOOM:
		_draw_flow_label(src_pos, tgt_pos, wps, flow_watts, false, "", col,
			float(flow_est.get("volts", 0.0)))
	_draw_connection_waypoint_handles(conn, center)


# Flow-rate labels on wires (Test mode only — callers gate on `flowing`).
const WIRE_LABEL_MIN_ZOOM := 0.8
const WIRE_LABEL_FONT_PX := 10.0   # graph-space design size (× _zoom on draw)

## Small readout pill at the wire midpoint: "512 W" / "1.20 kW" for electrical,
## "6.3 L/h" for typed resources.
func _draw_flow_label(src_pos: Vector2, tgt_pos: Vector2, wps: Array,
		value: float, is_resource: bool, kind: String, wire_col: Color,
		volts: float = 0.0) -> void:
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
		# Volts alongside watts: on a DC wire the voltage is the thing that
		# changes with series/parallel wiring, and it is what decides whether a
		# controller or battery can accept the string at all.
		if volts > 0.5:
			txt += "  ·  %.0f V" % volts

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

	_draw_bezier_stroke(from, c1, c2, to, 24,
		Color(col.r, col.g, col.b, col.a * 0.18), maxf(1.4, width * 0.6))
	_draw_bezier_stroke(from, c1, c2, to, 26, Color(0.01, 0.01, 0.03, 0.28), body_w + 2.0)
	if flow_active and gscale > 0.01:
		var glow_a := 0.08 + 0.14 * gscale
		_draw_bezier_stroke(from, c1, c2, to, 28,
			Color(col.r, col.g, col.b, glow_a), body_w + 2.4 + 2.6 * gscale)
	var core := Color(
		lerpf(col.r, 1.0, 0.16 * gscale),
		lerpf(col.g, 1.0, 0.14 * gscale),
		lerpf(col.b, 1.0, 0.10 * gscale),
		0.68 + 0.28 * gscale if flow_active else col.a)
	_draw_bezier_stroke(from, c1, c2, to, 32, core, maxf(1.8, body_w))
	if flow_active and gscale > 0.01:
		_draw_bezier_stroke(from, c1, c2, to, 32,
			Color(1.0, 1.0, 1.0, 0.12 + 0.18 * gscale), maxf(1.0, body_w * 0.22))
		_draw_resource_flow_arrows_bezier(from, c1, c2, to, col, body_w, reverse_chase, gscale)


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
		var to_t_out: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_out = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_out = (from - to).normalized()
		_draw_radiant_wire_bezier(from, from_t, to, to_t_out, col, width, flow_active, curve_tension, flow_rate, res_kind)


func _draw_resource_wire_path(points: Array, end_tangents: Array,
		col: Color, width: float, flow_active: bool,
		reverse_chase: bool, curve_tension: float = 1.0,
		flow_rate: float = 0.0, resource_kind: String = "", sankey_scale: bool = true) -> void:
	if points.size() < 2:
		return
	for seg: int in range(points.size() - 1):
		var from: Vector2 = points[seg] as Vector2
		var to: Vector2 = points[seg + 1] as Vector2
		var from_t: Vector2
		var to_t_out: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_out = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_out = (from - to).normalized()
		_draw_resource_wire_bezier(from, from_t, to, to_t_out, col, width, false,
				reverse_chase, curve_tension, flow_rate, resource_kind, sankey_scale)
	if flow_active:
		var sample_fn := func(t: float) -> Vector2:
			return _sample_wire_path(points, end_tangents, t, curve_tension)
		var gscale := ResourceEdgeVis.glow_scale(resource_kind, flow_rate, true)
		var body_w := width if not sankey_scale else ResourceEdgeVis.body_width(width, gscale)
		_draw_resource_flow_arrows_on_sample(sample_fn, col, body_w, reverse_chase, gscale)


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
		draw_line(a, b, Color(col.r, col.g, col.b, col.a * 0.18), maxf(1.4, width * 0.6))
		if flow_active and gscale > 0.01:
			var glow_a := 0.08 + 0.14 * gscale
			draw_line(a, b, Color(col.r, col.g, col.b, glow_a), body_w + 1.8 + 2.0 * gscale)
		draw_line(a, b, col, maxf(1.8, body_w))
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
			for seg: Dictionary in segs:
				if dist <= float(seg.get("len", 0.0)):
					var seg_a: Vector2 = seg.get("a", Vector2.ZERO)
					var seg_b: Vector2 = seg.get("b", Vector2.ZERO)
					var seg_start_len: float = float(seg.get("len", 0.0)) - seg_a.distance_to(seg_b)
					var seg_len: float = maxf(seg_a.distance_to(seg_b), 0.001)
					var u: float = (dist - seg_start_len) / seg_len
					return seg_a.lerp(seg_b, clampf(u, 0.0, 1.0))
			return points[points.size() - 1] as Vector2
		_draw_resource_flow_arrows_on_sample(sample_fn, col, body_w, reverse_chase, gscale)


## Glow underlay + main stroke + moving chase (source → target; `reverse` when battery discharges).
func _draw_wire_bezier(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2,
		col: Color, width: float, flow_active: bool,
		flow_watts: float, reverse_chase: bool, curve_tension: float = 1.0) -> void:
	var ctrl := _wire_bezier_controls(from, from_tang, to, to_tang_in, curve_tension)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]
	var gscale := _wire_glow_scale_from_watts(flow_watts)
	var body_w := maxf(2.2, width + 0.6 + gscale * 1.3)

	# Base depth stroke
	_draw_bezier_stroke(from, c1, c2, to, 30, Color(0.01, 0.01, 0.03, 0.32), body_w + 2.4)
	# Colored glow
	var glow_alpha := (0.12 + 0.20 * gscale) if flow_active else 0.08
	_draw_bezier_stroke(from, c1, c2, to, 30, Color(col.r, col.g, col.b, glow_alpha), body_w + 3.0 + 3.2 * gscale)
	# Main stroke
	var core := Color(lerpf(col.r, 1.0, 0.20 * gscale), lerpf(col.g, 1.0, 0.18 * gscale), lerpf(col.b, 1.0, 0.12 * gscale), 0.72 + 0.26 * gscale)
	_draw_bezier_stroke(from, c1, c2, to, 34, core, body_w)
	# Hot inner line
	_draw_bezier_stroke(from, c1, c2, to, 34, Color(1.0, 1.0, 1.0, 0.18 + 0.28 * gscale), maxf(1.0, body_w * 0.24))

	if flow_active:
		# Number of arrows scales with power (1–6) so high-wattage wires feel more alive
		var gscale_v2 := _wire_glow_scale_from_watts(flow_watts)
		var arrow_count := 3 + int(gscale_v2 * 3.0)
		var arrow_gap   := maxf(0.12, 0.22 - gscale_v2 * 0.07)
		var arrow_t     := fposmod(_flow_phase * 0.27, 1.0)
		if reverse_chase:
			arrow_t = 1.0 - arrow_t
		for i in arrow_count:
			var t := fposmod(arrow_t + float(i) * arrow_gap, 1.0)
			ResourceEdgeVis.draw_bezier_flow_arrow(
					self, from, c1, c2, to, t, col, body_w, reverse_chase, gscale_v2)


func _wire_chase_count(gscale: float) -> int:
	# High-speed / wire LOD: one lead dot. Otherwise power-scale only (no
	# timescale bonus — that used to *increase* draw cost at Max).
	if _wire_lod_simplify or _high_speed_lod:
		return 1
	return WIRE_CHASE_COUNT + int(gscale * 3.0)


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
		var to_t_out: Vector2
		if seg == 0:
			from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
		else:
			from_t = (to - from).normalized()
		if seg == points.size() - 2:
			to_t_out = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
		else:
			to_t_out = (from - to).normalized()
		_draw_wire_bezier(from, from_t, to, to_t_out, col, width, false, flow_watts, reverse_chase, curve_tension)
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
	var chase_count: int = _wire_chase_count(gscale)
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
	var radius_px := float(conn.get("_draw_corner_px",
			_conn_corner_radius_graph(conn) * _zoom))
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
	var style := _effective_line_style(conn)
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
		if view_mode == GraphSiteLayout.VIEW_ELEVATION:
			r = clampf(GraphSiteLayout.px_per_m(_zoom) * 0.22, 3.0, 7.0)
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
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		pick_r = clampf(GraphSiteLayout.px_per_m(_zoom) * 0.35, 8.0, 14.0)
	elif _touch_input_active():
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
	var tgt_t_out := (tgt.get("tangent", Vector2.RIGHT) as Vector2)
	return _build_orthogonal_polyline(
		pts, [src.get("tangent", Vector2.RIGHT) as Vector2, tgt_t_out])


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
	var tgt_t_out := (tgt.get("tangent", Vector2.RIGHT) as Vector2)
	var poly := _build_orthogonal_polyline(
		pts, [src.get("tangent", Vector2.RIGHT) as Vector2, tgt_t_out])
	if apply_rounding:
		var r_px := float(conn.get("_draw_corner_px",
				_conn_corner_radius_graph(conn) * _zoom))
		poly = _round_polyline_corners(poly, maxf(6.0, r_px))
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
			
	var style: String = _effective_line_style(conn)
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
	var style := _effective_line_style(conn)
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
	var to_t_out: Vector2
	if seg == 0:
		from_t = end_tangents[0] as Vector2 if end_tangents.size() > 0 else (to - from).normalized()
	else:
		from_t = (to - from).normalized()
	if seg == segs - 1:
		to_t_out = end_tangents[1] as Vector2 if end_tangents.size() > 1 else _incoming_tangent((to - from).normalized())
	else:
		to_t_out = (from - to).normalized()
	var ctrl := _wire_bezier_controls(from, from_t, to, to_t_out, curve_tension)
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

	# Pinned PBIs live on the fixed top bar — route their port to the pill tab so
	# connection wires anchor to the bar instead of a hidden graph-space node.
	if _pbi_pinned_active() and str(item.get("type", "")) == "pbi":
		var pill: Dictionary = _pbi_pill_rects.get(item_id, {}) as Dictionary
		if not pill.is_empty():
			var pport: Dictionary = pill.get("port", {}) as Dictionary
			return {
				"pos":     pport.get("pos", Vector2.ZERO) as Vector2,
				"tangent": pport.get("tangent", Vector2(0.0, 1.0)) as Vector2,
			}

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


## Human-readable port hint for hover tooltips: "AC Power OUT", "Water IN",
## "PV DC + IN" — name + direction only, never raw item/handle ids.
func port_hover_text(item_id: String, handle_id: String, pol: String,
		rk: String) -> String:
	var itype := ""
	if model != null:
		itype = str(model.get_item(item_id).get("type", ""))
	var hid := handle_id.to_lower()
	var dir := ""
	if hid.find("out") != -1:
		dir = "OUT"
	elif hid.find("in") != -1:
		dir = "IN"
	var name := ""
	match pol:
		"resource":
			name = ResourceKinds.display_name(ResourceKinds.normalize_kind(rk)) \
				if not rk.is_empty() else "Resource"
		"ac":
			name = "AC Power"
			if dir.is_empty():
				dir = "OUT"
		"pv":
			name = "PV String"
		"positive", "smart_battery":
			name = "DC +"
		"negative":
			name = "DC −"
		_:
			name = handle_id.capitalize()
	# Context: a controller's pv* ports RECEIVE the string; its battery* ports
	# are the (bidirectional) bank terminals; generator DC terminals produce.
	if hid.begins_with("pv") and (pol == "positive" or pol == "negative"):
		name = "PV %s" % name
		if dir.is_empty():
			dir = "IN"
	elif hid.begins_with("battery"):
		name = "Battery %s" % name
	elif dir.is_empty() and (pol == "positive" or pol == "negative") \
			and itype in ["panel", "wind", "hydro", "csp"]:
		dir = "OUT"
	return ("%s %s" % [name, dir]).strip_edges()


## Infers the outgoing tangent direction from a handle's fractional position.
## Ambient "documentary" inputs: sunlight into a panel / grow bed, wind into a
## turbine. The sim NEVER requires these wires — the resource is ambient across
## the whole Sphere of Influence and reaches every receiver regardless (see
## solar_pbi_selftest) — so an always-on dot is pure clutter competing with the
## DC ports that DO carry the circuit. Hidden by default; revealed when the
## node is selected (so the wire stays drawable) or already wired.
static func is_ambient_doc_handle(itype: String, handle_id: String) -> bool:
	match itype:
		"panel", "plant":
			return handle_id == "sunlight_in"
		"wind":
			return handle_id == "wind_in"
	return false


## One pass over the connections instead of a per-node wired scan (that would
## be O(nodes x connections) every frame / every mouse move). Rebuilt at the
## top of _draw() and of _port_at_screen, so it is never more than one frame
## stale for either the visual or the hit-test path.
func _refresh_ambient_wired_ports() -> void:
	_ambient_wired_ports.clear()
	if model == null:
		return
	for conn: Dictionary in model.connections:
		if str(conn.get("polarity", "")) != "resource":
			continue
		var kind := ResourceKinds.normalize_kind(str(conn.get("resource_type", "")))
		if kind != "sunlight" and kind != "wind":
			continue
		_ambient_wired_ports["%s|%s" % [
			str(conn.get("source_item_id", "")), str(conn.get("source_handle_id", ""))]] = true
		_ambient_wired_ports["%s|%s" % [
			str(conn.get("target_item_id", "")), str(conn.get("target_handle_id", ""))]] = true


## True when an ambient documentary port should be drawn AND grabbable. The two
## must agree: an invisible-but-live port would silently steal the drag that was
## meant to move the node.
func _ambient_doc_handle_shown(item: Dictionary, handle_id: String) -> bool:
	var iid := str(item.get("id", ""))
	if iid == selected_item_id or selected_item_ids.has(iid):
		return true
	return _ambient_wired_ports.has("%s|%s" % [iid, handle_id])


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
	# Site prefer_3d / none: schematic wires don't steal 3D conduit picks.
	if view_mode == GraphSiteLayout.VIEW_SITE and site_wire_mode != "metro":
		return {}
	# Elevation with live SoI CT: prefer world conduits over 2D bezier hits.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and soi_preview_service != null \
			and is_instance_valid(soi_preview_service) \
			and bool(soi_preview_service.get("active")):
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
		var tgt_t_out := (tgt.get("tangent", Vector2.RIGHT) as Vector2)
		var wps: Array = _waypoints_screen(conn, center)
		var style: String = _effective_line_style(conn)
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
				from, src.get("tangent", Vector2.RIGHT) as Vector2, to, tgt_t_out, curve_t)
			for i in range(17):
				var t := float(i) / 16.0
				if from.bezier_interpolate(ctrl["c1"], ctrl["c2"], to, t).distance_to(screen_pos) < PICK_DIST:
					hit = true
					break
		else:
			var pts: Array = [from] + wps + [to]
			for i in range(33):
				var t := float(i) / 32.0
				if _sample_wire_path(pts, [src.get("tangent", Vector2.RIGHT), tgt_t_out], t, curve_t).distance_to(screen_pos) < PICK_DIST:
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

## Set by SystemGraphView after the SoI preview service is created. When the
## preview camera is orbited (tilted off the default top-down / side-on pose)
## in Site/Elevation, the camera becomes the projection authority so chips and
## wires track the orbit; otherwise the proven 2D disc projection is used.
var soi_preview_service = null


## True when the SoI preview camera should drive physical-view projection.
## Elevation section: always (locks 2D DEM/pond/ports to the CT camera).
## Site Plan: whenever the live top-down preview is active (orbited or not),
## so overlays track tilt instead of sticking to flat disc math.
func _phys_camera_projection_active() -> bool:
	if not _is_physical_view():
		return false
	if soi_preview_service == null or not is_instance_valid(soi_preview_service):
		return false
	if not soi_preview_service.has_method("is_projection_authority"):
		return false
	if not bool(soi_preview_service.call("is_projection_authority")):
		return false
	if view_mode == GraphSiteLayout.VIEW_ELEVATION \
			and soi_preview_service.has_method("is_section_mode") \
			and bool(soi_preview_service.call("is_section_mode")):
		return true
	if view_mode == GraphSiteLayout.VIEW_SITE and soi_live_preview:
		return true
	return bool(soi_preview_service.call("is_phys_orbited"))


## Vertical exaggeration used for flat (non-camera) elev mapping.
## When the 3D section backdrop is live, force 1× so 2D never stretches vs the CT.
func _elev_exaggeration_draw() -> float:
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and soi_live_preview:
		return 1.0
	return maxf(elevation_exaggeration, 0.001)


## World-space centre of a placed physical item (SoI centre + site metres, Y=elevation).
func _phys_item_world_center(item: Dictionary) -> Vector3:
	var site := GraphSiteLayout.site_xz(item)
	var elev := _elevation_m_for_item(item)
	var c := Vector3.ZERO
	var soi := _cached_autoload("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		c = soi.call("world_center")
	return Vector3(c.x + site.x, elev, c.z + site.y)


## Project a placed item's centre to canvas-local pixels via the preview camera.
## Returns Vector2 or null (behind camera / projection unavailable).
func _phys_project_item_center(item: Dictionary) -> Variant:
	if not _phys_camera_projection_active():
		return null
	return soi_preview_service.call("world_to_canvas", _phys_item_world_center(item))

func _draw() -> void:
	# Dynamic lookup — autoload globals aren't available while this script is
	# compiled as a preload dependency of offline selftests (machine_selftest).
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.begin("gv_draw")
	_controller_reset_rects.clear()
	_refresh_ambient_wired_ports()
	_alert_seen_this_draw = false
	# Destroy-FX camera shake. Purely visual — one canvas-item transform for the
	# whole pass (including the V2 subclass's additions); hit-testing works off
	# _pan/_zoom and is deliberately untouched, so input never desyncs.
	var _fx_shake := _fx_shake_now()
	if _fx_shake != Vector2.ZERO:
		draw_set_transform(_fx_shake, 0.0, Vector2.ONE)
	# Populate the per-draw visible-items/connections cache for this whole pass
	# (base + any V2 super._draw extension). Refreshed every draw so moves/adds
	# show up; the model is immutable within a single draw.
	_cached_visible_items = _compute_visible_items()
	_cached_visible_connections = _compute_visible_connections()
	_twin_hidden_cache.clear()
	_draw_cache_active = true
	var fill := Color(C_CANVAS_BG.r, C_CANVAS_BG.g, C_CANVAS_BG.b, C_CANVAS_BG.a * canvas_bg_alpha)
	if soi_live_preview:
		_draw_canvas_fill_with_soi_hole(fill)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), fill)
	_draw_dot_grid()
	_draw_soi_background()
	if not siphon_lab_active:
		_draw_unplaced_tray()

	if model != null and _visible_items().size() > 0:
		_draw_connections()
		for item: Dictionary in _visible_items():
			_render_item(item)
		if not siphon_lab_active:
			for item: Dictionary in _visible_items():
				_draw_item_overlays(item)
			for item2: Dictionary in _visible_items():
				_draw_resize_handle(item2)
	elif model != null and not siphon_lab_active and not _is_physical_view() \
			and not soi_live_preview:
		_draw_empty_state_prompt()
	# Derive alert presence from what we actually drew, so tick() can pick a
	# coarse animation cadence without a separate model scan. If the state just
	# appeared, kick one redraw so the pulse cadence engages immediately.
	if _alert_seen_this_draw and not _alert_nodes_present:
		queue_redraw()
	_alert_nodes_present = _alert_seen_this_draw
	# Cache stays populated on the instance; a V2 override re-enables it for its
	# extra passes (arrays are still valid — model can't change between passes).
	_draw_cache_active = false

	_draw_scope_portal_pills()       # promoted-port docks when inside a super-node
	_draw_pbi_bar()                  # fundamental-resource pills pinned to top edge
	# Site Plan: only the live Preview ghost (not designated hillside polys) —
	# designated watershed stays a freeform graph node, not a default map outline.
	if view_mode == GraphSiteLayout.VIEW_SITE:
		_draw_npc_desire_site()   # worn-in paths beneath everything…
		_draw_watershed_overlays_site()
		_draw_npc_spaces_site()   # …destinations above them…
		_draw_npc_crew_sites()    # …active work sites (crews gather ON these)…
		_draw_npc_agents_site()   # …and the people walking between them
		_draw_prop_radial_preview()
	_draw_destroy_fx()
	_draw_temp_wire()                # always on top of everything
	if _marquee_selecting:
		var rect := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.14), true)
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65), false, 1.6)
	if pm != null:
		pm.end("gv_draw")


## Screen rects of the portal pills drawn for the current scope, so hit-testing
## (wire drops onto a pill) can bind an internal port to a promoted port.
## handle_id -> {rect: Rect2, direction: String}
var _portal_pill_rects: Dictionary = {}


## When editing inside a super-node's child canvas, dock a pill for each of the
## owner compound's promoted ports along the viewport edges (inputs across the TOP,
## outputs across the BOTTOM — matching the graph's top-to-bottom flow) so the
## external interface is visible and wireable from within.
func _draw_scope_portal_pills() -> void:
	_portal_pill_rects.clear()
	if model == null or active_scope_id == "root" or _is_physical_view():
		return
	var sc: Dictionary = model.get_scope(active_scope_id)
	var owner := str(sc.get("owner_compound_id", ""))
	if owner.is_empty():
		return
	var comp := model.get_item(owner)
	if comp.is_empty():
		return
	var eps: Array = (comp.get("specs", {}) as Dictionary).get("exposed_ports", []) as Array
	if eps.is_empty():
		return
	var ins: Array = []
	var outs: Array = []
	for ep_v in eps:
		var ep := ep_v as Dictionary
		if str(ep.get("direction", "in")) == "out":
			outs.append(ep)
		else:
			ins.append(ep)
	_draw_portal_pill_row(ins, true)
	_draw_portal_pill_row(outs, false)


## PBI icon glyphs by resource kind — small, readable at pill scale.
const _PBI_GLYPHS := {
	"sunlight": "☀", "solar": "☀",
	"water": "🌧", "rain": "🌧",
	"wind": "🌬", "mechanical": "🌬", "atmosphere": "🌬", "air": "🌬",
}


## Draw the fundamental-resource (PBI) nodes as a fixed screen-space bar pinned
## across the TOP edge of the canvas. Each pill exposes its downward "output"
## port (tab + dot) so wires drop onto the bar; the pill rect is cached in
## `_pbi_pill_rects` for hit-testing (wire-drop + click-select). Mirrors the
## `_draw_portal_pill_row` visual language.
func _draw_pbi_bar() -> void:
	_pbi_pill_rects.clear()
	if not _pbi_pinned_active() or model == null:
		return
	# Type-bucket index instead of a full model scan (needs ALL pbi items, which
	# _visible_items() excludes while pinned — so items_of_type is the right set).
	var pbis: Array = model.items_of_type("pbi")
	if pbis.is_empty():
		return

	var fnt := ThemeDB.fallback_font
	var pw := 138.0
	var ph := 30.0
	var gap := 12.0
	var total := pbis.size() * pw + (pbis.size() - 1) * gap
	var x0 := maxf(10.0, (size.x - total) * 0.5)
	var y := 8.0
	for i in pbis.size():
		var item: Dictionary = pbis[i]
		var iid := str(item.get("id", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var kind := str(specs.get("resource_kind", ""))
		var col := _wire_color_for_port("resource", kind)
		var is_active := bool(specs.get("active", true))
		var r := Rect2(Vector2(x0 + i * (pw + gap), y), Vector2(pw, ph))
		var is_sel := (iid == selected_item_id)

		# Body
		var body_a := 0.20 if is_active else 0.10
		draw_rect(r, Color(col.r, col.g, col.b, body_a), true)
		draw_rect(r, Color(col.r, col.g, col.b, 0.95 if is_active else 0.5),
			false, 2.0 if is_sel else 1.4)
		if is_sel:
			draw_rect(r.grow(2.0), Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.9),
				false, 1.6)

		# Label: glyph + name + value
		var glyph := str(_PBI_GLYPHS.get(kind, "◆"))
		var title := str(specs.get("name", iid))
		var value := str(specs.get("display_value", ""))
		draw_string(fnt, r.position + Vector2(8.0, ph * 0.5 + 5.0),
			"%s %s" % [glyph, title], HORIZONTAL_ALIGNMENT_LEFT,
			pw - 14.0, 12, C_TEXT)
		if not value.is_empty():
			draw_string(fnt, r.position + Vector2(8.0, ph - 4.0),
				value, HORIZONTAL_ALIGNMENT_LEFT, pw - 14.0, 9,
				Color(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.7))

		# Output port tab (points DOWN into the canvas) + connectable dot.
		var tab_c := Vector2(r.position.x + pw * 0.5, r.end.y)
		var tab := Rect2(tab_c - Vector2(9.0, 0.0), Vector2(18.0, 4.0))
		draw_rect(tab, Color(col.r, col.g, col.b, 0.95), true)
		draw_circle(tab_c, 4.0, Color(col.r, col.g, col.b, 0.95))

		_pbi_pill_rects[iid] = {
			"rect": r,
			"port": {
				"item_id":       iid,
				"handle_id":     "output",
				"polarity":      "resource",
				"resource_kind": kind,
				"pos":           tab_c,
				"tangent":       Vector2(0.0, 1.0),
				"hub":           false,
			},
		}


func _draw_portal_pill_row(ports: Array, is_input: bool) -> void:
	if ports.is_empty():
		return
	var fnt := ThemeDB.fallback_font
	var center := size * 0.5
	var pw := 118.0
	var ph := 24.0
	var gap := 12.0
	var total := ports.size() * pw + (ports.size() - 1) * gap
	var x0 := (size.x - total) * 0.5
	var y := 10.0 if is_input else size.y - ph - 10.0
	for i in ports.size():
		var ep := ports[i] as Dictionary
		var r := Rect2(Vector2(x0 + i * (pw + gap), y), Vector2(pw, ph))
		var col := PORT_COLORS.get(str(ep.get("polarity", "ac")), C_PRIMARY) as Color
		# A connectable stub tab pointing INTO the canvas (down for inputs on the
		# top edge, up for outputs on the bottom edge).
		var tab_c := Vector2(r.position.x + pw * 0.5, r.end.y if is_input else r.position.y)
		# Draw the connector wire from this portal port to the child node port it
		# fronts, so the external boundary stays visually linked to the interior.
		var child_info := _get_handle_info(str(ep.get("child_item_id", "")),
			str(ep.get("child_handle_id", "")), center)
		if not child_info.is_empty():
			var cpos: Vector2 = child_info.get("pos", Vector2.ZERO) as Vector2
			var from_pt := tab_c
			var to_pt := cpos
			if not is_input:
				from_pt = cpos
				to_pt = tab_c
			var wcol := Color(col.r, col.g, col.b, 0.5)
			# Follow the graph's selected wire style (Wire ▾) so portal
			# connectors read as part of the same circuit, not a thin overlay.
			var pstyle := _effective_line_style({})
			var pw_stroke := maxf(1.5, 2.2 * _zoom)
			if pstyle == "metro":
				_draw_wire_metro_path([from_pt, to_pt],
					[Vector2.DOWN, Vector2.DOWN], wcol, pw_stroke,
					false, 0.0, false, {"corner_radius": 14.0})
			elif pstyle == "orthogonal":
				_draw_wire_orthogonal_path([from_pt, to_pt],
					[Vector2.DOWN, Vector2.DOWN], wcol, pw_stroke,
					false, 0.0, false, {})
			else:
				var dy := absf(to_pt.y - from_pt.y) * 0.45 + 24.0
				var c1 := from_pt + Vector2(0.0, dy)
				var c2 := to_pt - Vector2(0.0, dy)
				var march := fmod(_flow_phase * 42.0, 16.0)
				_draw_bezier_stroke_dashed(from_pt, c1, c2, to_pt, 26, wcol,
					pw_stroke, 7.0, 6.0, march)
		draw_rect(r, Color(col.r, col.g, col.b, 0.16), true)
		draw_rect(r, Color(col.r, col.g, col.b, 0.9), false, 1.4)
		var label := str(ep.get("label", ""))
		if label.is_empty():
			label = str(ep.get("handle_id", ""))
		# Inputs flow down INTO the canvas (▾ leads); outputs flow down OUT (▾ trails).
		var glyph := "▾ " if is_input else ""
		var trail := " ▾" if not is_input else ""
		draw_string(fnt, r.position + Vector2(8.0, ph * 0.5 + 4.0),
			"%s%s%s" % [glyph, label, trail],
			HORIZONTAL_ALIGNMENT_LEFT, pw - 12.0, 12, C_TEXT)
		var tab := Rect2(tab_c - Vector2(9.0, 0.0) - Vector2(0.0, 0.0 if is_input else 4.0),
			Vector2(18.0, 4.0))
		draw_rect(tab, Color(col.r, col.g, col.b, 0.95), true)
		draw_circle(tab_c, maxf(3.0, 3.5 * _zoom), Color(col.r, col.g, col.b, 0.95))
		_portal_pill_rects[str(ep.get("handle_id", ""))] = {"rect": r, "direction": "in" if is_input else "out"}


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


## Bold, type-agnostic state overlay driven by specs["node_state"].
## RUNNING → green rounded highlight; READY/IDLE → no highlight; alerts →
## pulsing rounded red/amber halo + reason chip (+ smoke for faults).
func _draw_node_state_overlay(item: Dictionary, specs: Dictionary, rect: Rect2) -> void:
	var state := str(specs.get("node_state", ""))
	# Controllers flag faults via the legacy `destroyed` spec — treat that as
	# FAULT so they gain the chip + pulse without a separate view write.
	var destroyed := bool(specs.get("destroyed", false))
	if destroyed and not GraphNodeState.is_alert(state):
		state = GraphNodeState.FAULT
	# READY: no highlight (quiet — contrast with RUNNING's green halo).
	if GraphNodeState.is_ready(state):
		return
	if state == GraphNodeState.RUNNING:
		var gcol := GraphNodeState.C_RUNNING
		var grow_r := maxf(3.0, 5.0 * _zoom)
		_draw_rounded_state_highlight(rect.grow(grow_r * 0.55), gcol, 0.18, 0.0, 0)
		_draw_rounded_state_highlight(rect.grow(grow_r), gcol, 0.0, 0.92,
			maxf(2.0, 2.8 * _zoom))
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
	_draw_rounded_state_highlight(rect.grow(grow * 0.6), col, 0.16 * pulse, 0.0, 0)
	_draw_rounded_state_highlight(rect.grow(grow), col, 0.0, 0.9 * pulse,
		maxf(2.0, 3.0 * _zoom))

	# The destroy burst renders its own smoke for a few seconds; once it has
	# aged out, a wreck keeps smouldering until RESET so the damage stays
	# legible long after the blast (and behind the education card).
	if state == GraphNodeState.FAULT and (not destroyed or not _has_live_destroy_fx()):
		_draw_fault_smoke(rect)

	var reason := str(specs.get("node_state_reason", ""))
	if destroyed and reason.is_empty():
		reason = GraphNodeState.REASON_OVERVOLTAGE
	var kinds: Array = specs.get("node_state_kinds", []) as Array
	var chip := (GraphNodeState.state_icon(state) + " "
			+ GraphNodeState.chip_text(state, reason, kinds)).strip_edges()
	if not chip.is_empty():
		_state_badge.draw_badge(self, rect, chip, col, _zoom)


## Soft rounded halo matching node corner radius (StyleBoxFlat, not sharp draw_rect).
func _draw_rounded_state_highlight(rect: Rect2, col: Color, fill_a: float,
		border_a: float, border_w: float) -> void:
	if _sb_state_highlight == null:
		_sb_state_highlight = StyleBoxFlat.new()
	var radius := maxi(6, int(round(12.0 + minf(rect.size.x, rect.size.y) * 0.02)))
	_sb_state_highlight.set_corner_radius_all(radius)
	_sb_state_highlight.bg_color = Color(col.r, col.g, col.b, fill_a)
	if border_w > 0.0 and border_a > 0.0:
		_sb_state_highlight.set_border_width_all(maxi(1, int(round(border_w))))
		_sb_state_highlight.border_color = Color(col.r, col.g, col.b, border_a)
	else:
		_sb_state_highlight.set_border_width_all(0)
		_sb_state_highlight.border_color = Color(0, 0, 0, 0)
	draw_style_box(_sb_state_highlight, rect)


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
	# Site Plan: a ring is a highlight over a 3D twin. If the node's twin is hidden
	# from the 3D world (hidden_3d), draw nothing here — there's no model to mark.
	# (Freeform/Elevation still show it.)
	if view_mode == GraphSiteLayout.VIEW_SITE and _item_twin_is_hidden(item):
		return
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
		# Invisible ∞ culvert outlet — never drawn in Site/Elevation.
		if bool(specs.get("outlet_sink", false)):
			return
		# Elevation: pond body is the solid blue band — hide storage/catchment
		# chips (hydropower detail lives in Siphon Lab). Watershed hillside is
		# a twin of the pond (rain → tank), not a second bowl.
		if view_mode == GraphSiteLayout.VIEW_ELEVATION:
			if bool(specs.get("pond_storage", false)) \
					or (itype == "catchment" \
						and str(specs.get("catchment_kind", "")) in ["pond", "watershed"]) \
					or _is_pond_twin_hidden(item):
				return
			if not elev_show_chips:
				# Compact port pad (no inflated chip floors) so dots track metres.
				var port_rect := _elev_port_pad_rect(item, tl, sz)
				if is_sel:
					var border := C_SELECTED_BORDER
					draw_rect(port_rect, Color(border.r, border.g, border.b, 0.55),
							false, minf(1.25, ELEV_STROKE_MAX_PX))
				if elev_show_ports:
					_draw_item_handles(item, port_rect.position, port_rect.size)
				return
		# Pond surface catchment + hillside watershed share identity with the
		# pond_storage tank — draw only the tank chip (merged twin).
		if _is_pond_twin_hidden(item):
			return
		# Site Plan: circular transparent magnifier over the 3D twin (+ rim ports).
		if view_mode == GraphSiteLayout.VIEW_SITE:
			_draw_site_magnifier(item, Rect2(tl, sz), is_sel)
			_draw_item_handles(item, tl, sz)
			return
		_draw_site_plan_chip(item, Rect2(tl, sz), is_sel)
		if view_mode == GraphSiteLayout.VIEW_ELEVATION and elev_show_ports:
			_draw_item_handles(item, tl, sz)
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

	# Blocked-family vibration (behind frame). RUNNING / alert outline halos are
	# drawn in the overlay pass so they stay rounded and consistent across V1/V2.
	var node_state := str(specs.get("node_state", ""))
	if GraphNodeState.is_blocked_family(node_state):
		var offset = Vector2(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0)) * _zoom
		tl += offset
		rect.position += offset
		_draw_rounded_state_highlight(rect.grow(maxf(2.5, 3.0 * _zoom)),
			Color(0.9, 0.15, 0.2), 0.35, 0.0, 0)
	elif node_state.is_empty() and itype in ["appliance", "acload", "processor"]:
		# Legacy fallback for load nodes not yet writing node_state.
		var st := str(specs.get("current_state", "")).to_lower()
		var avg := float(specs.get("avg_watts", 0.0))
		if st == "on" or (st.is_empty() and avg > 0.5):
			_draw_rounded_state_highlight(rect.grow(maxf(2.5, 3.0 * _zoom)),
				GraphNodeState.C_RUNNING, 0.22, 0.0, 0)

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
	if itype in ["controller", "battery", "smartbattery"] and bool(specs.get("destroyed", false)):
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
			_draw_battery_body(body_rect, specs, iid, rect)
		"controller":
			_draw_controller_body(body_rect, specs, iid, rect)
		"compound":
			_draw_compound_body(body_rect, specs, item)
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
	# More sculpted rounded containers in V2.
	_draw_rounded_rect(Rect2(rect.position + Vector2(2.0, 3.0), rect.size), V2_NODE_SHADOW, 12)
	_draw_rounded_rect(rect, Color(0.07, 0.10, 0.19, 0.96), 12, Color(border_col.r * 0.55, border_col.g * 0.55, border_col.b * 0.55, 0.75), 1)
	_draw_rounded_rect(rect.grow(-1.5), Color(0, 0, 0, 0), 10, Color(border_col.r, border_col.g, border_col.b, 0.42), 1)


## True when the node should be drawn as a full-bleed icon/preview (no frame).
## Default ON when a GLB model_id is present; emoji-only nodes opt in via
## specs.icon_replaces_frame = true. The "card" display mode (View options ▾)
## forces classic framed cards for every node.
func _icon_replaces_frame(specs: Dictionary) -> bool:
	if node_display_mode == "card":
		return false
	var has_model := not str(specs.get("model_id", "")).is_empty()
	var has_icon := not str(specs.get("icon", "")).is_empty()
	if not has_model and not has_icon:
		return false
	if specs.has("icon_replaces_frame"):
		return bool(specs.get("icon_replaces_frame"))
	return has_model


## Full-node icon or GLB preview; ports + selection still drawn by the caller.
## The preview floats on the canvas (no dark plate behind it — the thumbnail
## texture is already alpha-transparent); an optional compact title band names
## the node (show_preview_labels).
func _draw_icon_as_node(rect: Rect2, specs: Dictionary, border_col: Color,
		is_sel: bool) -> void:
	var z := _zoom
	var pad := maxf(2.0, 3.0 * z)
	draw_rect(rect, Color(border_col.r, border_col.g, border_col.b,
		0.85 if is_sel else 0.30), false, maxf(1.0, 1.2 * z))
	var inner := rect.grow(-pad)
	if show_preview_labels:
		var band_h := clampf(15.0 * z, 9.0, 24.0)
		var title := str(specs.get("name", ""))
		if not title.is_empty() and rect.size.y > band_h * 2.0:
			_draw_title_band(rect, band_h, title, border_col)
			inner = Rect2(inner.position + Vector2(0.0, band_h),
				inner.size - Vector2(0.0, band_h))
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
	_draw_rounded_rect(band, Color(accent.r, accent.g, accent.b, 0.22), 11)
	_draw_rounded_rect(Rect2(band.position, Vector2(band.size.x, 2.0)), Color(V2_TITLE_GLOW.r, V2_TITLE_GLOW.g, V2_TITLE_GLOW.b, 0.72), 2)
	var fsize := _fit_title_font_size(band_h)
	var cy := rect.position.y + band_h * 0.5 + fsize * 0.38
	var pad_x := 10.0
	var max_w := maxf(8.0, rect.size.x - pad_x * 2.0)
	_draw_fitted_label(Vector2(rect.position.x + pad_x, cy), title, max_w, fsize, Color(0.93, 0.95, 0.99, 1.0))


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


# --- V2 draw chrome (promoted from graph_canvas_v2 — single source of truth) ---
# graph_canvas_v2 is the only canvas instantiated at runtime, so these are the
# implementations that actually render. Kept here (not in the subclass) so there is
# one copy to edit. The consts + rounded-rect + flow-arrow helpers are shared by
# several node/wire draw methods below.
const V2_NODE_SHADOW := Color(0.0, 0.0, 0.0, 0.26)
const V2_TITLE_GLOW := Color(0.13, 0.83, 0.93, 0.14)
const V2_PORT_RING := Color(0.95, 0.97, 1.0, 0.75)


func _draw_rounded_rect(rect: Rect2, fill: Color, radius: int, border_col: Color = Color(0, 0, 0, 0), border_w: int = 0) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(radius)
	if border_w > 0 and border_col.a > 0.0:
		sb.set_border_width_all(border_w)
		sb.border_color = border_col
	draw_style_box(sb, rect)


func _draw_resource_flow_arrows_bezier(from: Vector2, c1: Vector2, c2: Vector2, to: Vector2,
		col: Color, body_w: float, reverse: bool, gscale: float) -> void:
	ResourceEdgeVis.draw_bezier_flow_arrows(
			self, from, c1, c2, to, col, body_w, _flow_phase, reverse, gscale)


func _draw_resource_flow_arrows_on_sample(sample_fn: Callable, col: Color, body_w: float,
		reverse: bool, gscale: float) -> void:
	ResourceEdgeVis.draw_sample_flow_arrows(
			self, sample_fn, col, body_w, _flow_phase, reverse, gscale)


func _draw_battery_body(rect: Rect2, specs: Dictionary, item_id: String = "",
		full_rect: Rect2 = Rect2()) -> void:
	var fnt := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 3, 10.0, 12.0)
	# Destroyed (short circuit / overcharge): banner + reason + RESET button —
	# same contract as controllers; the press loop in _on_lmb_press is generic
	# over _controller_reset_rects, so registering here is all it takes.
	if bool(specs.get("destroyed", false)):
		var x0 := rect.position.x + 8.0
		var y0 := rect.position.y + fsize + 4.0
		draw_string(fnt, Vector2(x0, y0), "DESTROYED",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(1.0, 0.35, 0.35))
		y0 += fsize + 4.0
		draw_string(fnt, Vector2(x0, y0), str(specs.get("destroyed_reason", "Electrical fault")),
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
		return
	var soc := clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
	var x := rect.position.x + 8.0
	var y := rect.position.y + fsize + 4.0
	var kwh := float(specs.get("kwh", 0.0))
	draw_string(fnt, Vector2(x, y), "%.0f%%  %.1fkWh" % [soc * 100.0, kwh], HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.94, 0.99, 0.95, 1.0))
	y += fsize + 4.0

	# Battery silhouette: rounded can + top terminal cap.
	var body := Rect2(Vector2(x, y), Vector2(rect.size.x - 16.0, rect.size.y - (y - rect.position.y) - 6.0))
	_draw_rounded_rect(body, Color(0.07, 0.15, 0.12, 0.97), 9, Color(0.35, 0.90, 0.62, 0.52), 1)
	var cap_w := maxf(14.0, body.size.x * 0.22)
	var cap_h := 4.0
	var cap := Rect2(Vector2(body.position.x + (body.size.x - cap_w) * 0.5, body.position.y - cap_h - 1.0), Vector2(cap_w, cap_h))
	_draw_rounded_rect(cap, Color(0.18, 0.27, 0.22, 0.96), 2, Color(0.52, 0.95, 0.72, 0.35), 1)

	# Full-body reservoir: charge fills entire battery interior from bottom.
	var reservoir := Rect2(body.position + Vector2(3.0, 3.0), body.size - Vector2(6.0, 6.0))
	_draw_rounded_rect(reservoir, Color(0.04, 0.08, 0.07, 0.98), 6, Color(0.26, 0.40, 0.33, 0.8), 1)
	var fill_h := maxf(2.0, (reservoir.size.y - 2.0) * soc)
	var fill_col := Color(0.25, 0.92, 0.56, 0.96) if soc > 0.28 else Color(0.95, 0.63, 0.22, 0.95)
	var reservoir_fill := Rect2(
		Vector2(reservoir.position.x + 1.0, reservoir.position.y + reservoir.size.y - 1.0 - fill_h),
		Vector2(reservoir.size.x - 2.0, fill_h)
	)
	_draw_rounded_rect(reservoir_fill, fill_col, 5)
	draw_rect(Rect2(Vector2(reservoir_fill.position.x, reservoir_fill.position.y), Vector2(reservoir_fill.size.x, minf(2.0, reservoir_fill.size.y))), Color(0.88, 1.0, 0.92, 0.32), true)

	# Overlay text + optional per-cell bars float above the reservoir fill.
	var info_x := reservoir.position.x + 7.0
	var info_y := body.position.y + fsize
	var _chem_tag := BatteryChemistry.label(BatteryChemistry.infer(specs))
	var _v_line := "%.0fV  %.0fAh" % [float(specs.get("voltage", 12.0)), float(specs.get("ah", 0.0))]
	if not _chem_tag.is_empty():
		_v_line += "  " + _chem_tag
	draw_string(fnt, Vector2(info_x, info_y), _v_line, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), Color(0.80, 0.95, 0.87, 0.96))
	info_y += maxi(9, fsize - 1) + 3.0
	draw_string(fnt, Vector2(info_x, info_y), "Charge %.0f%%" % (soc * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), Color(0.66, 0.93, 0.77, 0.95))
	info_y += maxi(8, fsize - 2) + 5.0

	var cell_view_mode := bool(specs.get("cell_view_mode", false))
	var cell_gap := 2.0
	var cell_cols := 8 if cell_view_mode else 4
	var cell_area_w := maxf(22.0, reservoir.size.x - 14.0)
	var cw := (cell_area_w - float(cell_cols - 1) * cell_gap) / float(cell_cols)
	for i in range(cell_cols):
		var cp := Vector2(info_x + float(i) * (cw + cell_gap), info_y)
		var ch := maxf(9.0, reservoir.end.y - cp.y - 4.0)
		var crect := Rect2(cp, Vector2(cw, ch))
		_draw_rounded_rect(crect, Color(0.08, 0.21, 0.15, 0.52), 2, Color(0.46, 0.92, 0.69, 0.26), 1)
		var phase := _flow_phase + float(i) * 0.55
		var fill := clampf(soc + 0.07 * sin(phase), 0.06, 0.98)
		var fh := (crect.size.y - 2.0) * fill
		var cfill := Rect2(Vector2(crect.position.x + 1.0, crect.position.y + crect.size.y - 1.0 - fh), Vector2(crect.size.x - 2.0, fh))
		_draw_rounded_rect(cfill, Color(0.39, 0.90, 0.62, 0.78), 2)
	if cell_view_mode:
		draw_string(fnt, Vector2(info_x, rect.position.y + rect.size.y - 2.0), "Cell detail mode", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 2), Color(0.76, 0.96, 0.85, 0.92))


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
	# Live current-limit readout (GraphDcElectrical throttle telemetry): amber
	# when the controller is clipping the array — the tutorial's core feedback.
	if not destroyed and bool(specs.get("dc_clipped", false)):
		y += fsize + 3.0
		draw_string(fnt, Vector2(x, y), "⚡ %.0f W (%.0f V × %.0f A cap)" % [
				float(specs.get("dc_delivered_w", 0.0)),
				float(specs.get("dc_bus_v", 0.0)),
				float(specs.get("max_charge_amps", 0.0))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 2), Color(0.95, 0.72, 0.20))
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


## Deterministic per-particle noise in [0,1) — the canvas redraws on an interval
## rather than every frame, so particle angles/speeds must not be re-rolled.
static func _fx_rand(seed_v: int, idx: int, salt: int) -> float:
	var h: int = absi((seed_v * 73856093) ^ (idx * 19349663) ^ (salt * 83492791))
	return float(h % 1000003) / 1000003.0


## Ballistic particle position: radial launch with linear drag, plus gravity.
static func _fx_particle_pos(c: Vector2, ang: float, spd: float, t: float,
		scale_px: float) -> Vector2:
	var dist := spd * (1.0 - exp(-2.6 * t)) / 2.6
	return c + Vector2(cos(ang), sin(ang)) * dist \
		+ Vector2(0.0, 340.0 * scale_px * t * t * 0.5)


func _draw_destroy_fx() -> void:
	for fx_v in _destroy_fx:
		if not (fx_v is Dictionary):
			continue
		var fx: Dictionary = fx_v
		var age := float(fx.get("age", 0.0))
		var c: Vector2 = fx.get("center", Vector2.ZERO)
		var sd := int(fx.get("seed", 0))
		var s := maxf(_zoom, 0.35)

		# 1) Flash — the whole canvas blows out white for a couple of frames.
		var fl := fx_stage(age, 0.0, 0.08)
		if fl < 1.0:
			draw_rect(Rect2(Vector2.ZERO, size),
				Color(1.0, 0.96, 0.88, (1.0 - fl) * 0.55))

		# 1b) Second arc-flash a beat later — a re-strike, tighter and bluer
		# than the main blast, plus its own small shockwave so the burst reads
		# as two distinct hits rather than one long fade.
		var crack := fx_stage(age, FX_CRACK_AT, FX_CRACK_AT + FX_CRACK_S)
		if crack > 0.0 and crack < 1.0:
			draw_rect(Rect2(Vector2.ZERO, size),
				Color(0.85, 0.92, 1.0, (1.0 - crack) * 0.30))
			draw_circle(c, (10.0 + 46.0 * crack) * s,
				Color(0.80, 0.90, 1.0, (1.0 - crack) * 0.55))
			draw_arc(c, (16.0 + 90.0 * crack) * s, 0.0, TAU, 40,
				Color(0.85, 0.94, 1.0, (1.0 - crack) * 0.6),
				maxf(2.5 * (1.0 - crack), 0.6) * s, true)

		# 2) Fireball — nested shells cooling along the ember ramp.
		var fb := fx_stage(age, 0.0, 0.35)
		if fb < 1.0:
			var r := (14.0 + 62.0 * (1.0 - pow(1.0 - fb, 3.0))) * s
			for k in 5:
				var kt := float(k) / 4.0
				var col := fx_fire_color(kt * 0.7 + fb * 0.3)
				col.a = (1.0 - fb) * (1.0 - kt * 0.55)
				draw_circle(c, r * (1.0 - kt * 0.62), col)

		# 3) Shockwave rings.
		for w in 2:
			var w0 := 0.05 + float(w) * 0.12
			var sw := fx_stage(age, w0, w0 + 0.75)
			if sw > 0.0 and sw < 1.0:
				draw_arc(c, (10.0 + 150.0 * sw) * s, 0.0, TAU, 48,
					Color(1.0, 0.86, 0.62, (1.0 - sw) * 0.5),
					maxf(3.0 * (1.0 - sw), 0.6) * s, true)

		# 4) Embers — drawn as short motion streaks, not static dots.
		for i in FX_EMBERS:
			var life := 0.7 + _fx_rand(sd, i, 3) * 0.9
			if age > life:
				continue
			var ang := _fx_rand(sd, i, 1) * TAU
			var spd := (140.0 + _fx_rand(sd, i, 2) * 320.0) * s
			var u := age / life
			var col := fx_fire_color(u)
			col.a = (1.0 - u) * 0.95
			draw_line(_fx_particle_pos(c, ang, spd, maxf(age - 0.045, 0.0), s),
				_fx_particle_pos(c, ang, spd, age, s),
				col, maxf(2.4 * (1.0 - u), 0.7) * s, true)

		# 5) Debris — tumbling dark chunks.
		for i in FX_DEBRIS:
			var life := 0.8 + _fx_rand(sd, i, 13) * 0.6
			if age > life:
				continue
			var p := _fx_particle_pos(c, _fx_rand(sd, i, 11) * TAU,
				(90.0 + _fx_rand(sd, i, 12) * 190.0) * s, age, s)
			var spin := (_fx_rand(sd, i, 14) - 0.5) * 18.0 * age
			var half := (2.5 + _fx_rand(sd, i, 15) * 3.5) * s
			var quad := PackedVector2Array()
			for k in 4:
				var a2 := spin + float(k) * TAU * 0.25 + PI * 0.25
				quad.append(p + Vector2(cos(a2), sin(a2)) * half)
			draw_colored_polygon(quad,
				Color(0.16, 0.14, 0.15, clampf(1.0 - age / life, 0.0, 1.0)))

		# 6) Smoke — rises and spreads, outlasting the fire.
		var sm := fx_stage(age, 0.25, FX_LIFETIME)
		if sm > 0.0 and sm < 1.0:
			for i in 9:
				var p := c + Vector2(cos(_fx_rand(sd, i, 21) * TAU),
						sin(_fx_rand(sd, i, 21) * TAU)) \
						* (8.0 + _fx_rand(sd, i, 22) * 34.0) * s * (0.5 + sm) \
					- Vector2(0.0, (30.0 + _fx_rand(sd, i, 23) * 70.0) * s * sm)
				draw_circle(p,
					(7.0 + _fx_rand(sd, i, 24) * 9.0) * s * (0.6 + sm * 1.4),
					Color(0.30, 0.29, 0.31, (1.0 - sm) * 0.34))


func _has_live_destroy_fx() -> bool:
	return not _destroy_fx.is_empty()


## Summed shake offset from every live burst (zero once they age out).
func _fx_shake_now() -> Vector2:
	var out := Vector2.ZERO
	for fx_v in _destroy_fx:
		if fx_v is Dictionary:
			out += fx_shake_offset(float((fx_v as Dictionary).get("age", 0.0)))
	return out


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


## True when a compound should render like a single battery (tall SOC fill)
## instead of a generic supernode miniature / bank grid. Covers Combine →
## Battery Bank (`compound_kind`), opt-in `display_as_battery`, and component
## defs whose id is a battery bank (e.g. StarShade's `starshade_battery_bank`).
func _compound_displays_as_battery(specs: Dictionary) -> bool:
	if bool(specs.get("display_as_battery", false)):
		return true
	if str(specs.get("compound_kind", "")) == "battery_bank":
		return true
	var def_id := str(specs.get("definition_id", "")).to_lower()
	return def_id.contains("battery_bank")


## Energy-weighted SOC of battery/smartbattery children inside a compound's
## child scope (parallel or series — energy weighting is correct for both when
## SolarUI keeps leaf SOCs in lock-step). Falls back to specs.soc when empty.
func _aggregate_child_battery_soc(compound: Dictionary) -> float:
	var specs: Dictionary = compound.get("specs", {}) as Dictionary
	var fallback := clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
	if model == null:
		return fallback
	var child_scope := str(compound.get("child_scope_id", ""))
	if child_scope.is_empty():
		return fallback
	var weighted := 0.0
	var total_kwh := 0.0
	var kids: Array = model.get_items_in_scope(child_scope) if model.has_method("get_items_in_scope") else []
	for kid_v: Variant in kids:
		if not (kid_v is Dictionary):
			continue
		var kid: Dictionary = kid_v as Dictionary
		var kt := str(kid.get("type", ""))
		if kt not in ["battery", "smartbattery"]:
			continue
		var ksp: Dictionary = kid.get("specs", {}) as Dictionary
		var kwh := float(ksp.get("kwh", 0.0))
		if kwh <= 0.0:
			kwh = 1.0
		weighted += kwh * clampf(float(ksp.get("soc", 0.5)), 0.0, 1.0)
		total_kwh += kwh
	if total_kwh <= 0.0:
		return fallback
	return weighted / total_kwh


func _draw_compound_body(rect: Rect2, specs: Dictionary, item: Dictionary = {}) -> void:
	# Optional banner: a super-node can present a 2D image of its real-world
	# subject (the StarShade GLB, etc.) in place of the child-graph miniature —
	# same GLB-thumbnail path processor cards use.
	if _draw_compound_banner(rect, specs):
		return
	# When the super-node is drawn large enough on screen, show a live miniature
	# of its child canvas (TouchDesigner-style) instead of a plain text summary,
	# so a collapsed group still reads as "a system inside a node". LOD-gated on
	# the on-screen rect size so deep graphs stay cheap.
	if _draw_compound_miniature(rect, specs, item):
		return
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


## Draw a super-node's 2D banner image (its `model_id` GLB thumbnail) filling the
## body, with a name header. Returns true when it drew. Opt-in via `node_banner`
## (or any generic compound that carries a `model_id`); an aerial/photo subject
## reads as "this node IS a real thing" rather than a graph-in-a-box.
func _draw_compound_banner(rect: Rect2, specs: Dictionary) -> bool:
	if not bool(specs.get("node_banner", false)):
		return false
	if str(specs.get("model_id", "")).is_empty():
		return false
	if rect.size.x < 24.0 or rect.size.y < 24.0:
		return false
	# The title band already shows the name — fill the whole body with the image.
	var img := rect.grow(-3.0)
	if img.size.x < 8.0 or img.size.y < 8.0:
		return true
	# width_frac 1.0 → fill the body zone with the aspect-fit GLB thumbnail.
	if not _draw_model_preview_zone(img, specs, 1.0):
		# No cached render yet (request is queued): show a soft placeholder so the
		# node doesn't fall back to the miniature and flicker when the image lands.
		draw_rect(img, Color(0.05, 0.08, 0.14, 0.85), true)
		var fnt := ThemeDB.fallback_font
		var glyph := str(specs.get("icon", "✨"))
		var fs := int(clampf(minf(img.size.x, img.size.y) * 0.5, 8.0, 120.0))
		var gsz := fnt.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(fnt, img.position + Vector2(
			(img.size.x - gsz.x) * 0.5, (img.size.y + gsz.y * 0.55) * 0.5),
			glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.6, 0.7, 0.95, 0.5))
	return true


## Minimum on-screen body size (px) before the child-canvas miniature draws.
const COMPOUND_MINI_MIN_PX := 66.0


## Live miniature of a generic super-node's child scope, fitted into `rect`.
## Returns true when it drew (caller then skips the text summary). Only generic
## compounds (kind == "") get this — arrays/banks/load-groups have bespoke bodies.
func _draw_compound_miniature(rect: Rect2, specs: Dictionary, item: Dictionary) -> bool:
	if str(specs.get("compound_kind", "")) != "":
		return false
	# Battery banks render as one tall SOC cell (V2 freeform), not a mini graph.
	if _compound_displays_as_battery(specs):
		return false
	if model == null or item.is_empty():
		return false
	if rect.size.x < COMPOUND_MINI_MIN_PX or rect.size.y < COMPOUND_MINI_MIN_PX:
		return false
	var child_scope := str(item.get("child_scope_id", ""))
	if child_scope.is_empty():
		return false
	var kids: Array = model.get_items_in_scope(child_scope)
	if kids.is_empty():
		return false
	# Child bounding box in graph coords.
	var min_x := 1e20
	var min_y := 1e20
	var max_x := -1e20
	var max_y := -1e20
	for k_v in kids:
		var k := k_v as Dictionary
		var kx := float(k.get("x", 0.0))
		var ky := float(k.get("y", 0.0))
		var kw := float(k.get("width", 120.0))
		var kh := float(k.get("height", 90.0))
		min_x = minf(min_x, kx); min_y = minf(min_y, ky)
		max_x = maxf(max_x, kx + kw); max_y = maxf(max_y, ky + kh)
	var span_x := maxf(max_x - min_x, 1.0)
	var span_y := maxf(max_y - min_y, 1.0)
	# Header strip for the name, remainder is the preview viewport.
	var header := clampf(rect.size.y * 0.22, 10.0, 20.0)
	var pad := 4.0
	var view := Rect2(rect.position + Vector2(pad, header),
		rect.size - Vector2(pad * 2.0, header + pad))
	if view.size.x <= 2.0 or view.size.y <= 2.0:
		return false
	var s := minf(view.size.x / span_x, view.size.y / span_y)
	var off := view.position + (view.size - Vector2(span_x, span_y) * s) * 0.5
	var to_mini := func(gx: float, gy: float) -> Vector2:
		return off + Vector2(gx - min_x, gy - min_y) * s
	# Name header.
	var fnt := ThemeDB.fallback_font
	var name_s := str(specs.get("name", "Super Node"))
	var hf := clampf(header - 4.0, 7.0, 13.0)
	draw_string(fnt, rect.position + Vector2(6.0, hf), name_s,
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, int(hf), C_TEXT_S)
	# Wires first (behind node chips).
	var centers: Dictionary = {}
	for k_v in kids:
		var k := k_v as Dictionary
		var cx := float(k.get("x", 0.0)) + float(k.get("width", 120.0)) * 0.5
		var cy := float(k.get("y", 0.0)) + float(k.get("height", 90.0)) * 0.5
		centers[str(k.get("id", ""))] = to_mini.call(cx, cy)
	for c_v in model.get_connections_in_scope(child_scope):
		var c := c_v as Dictionary
		var a: Variant = centers.get(str(c.get("source_item_id", "")))
		var b: Variant = centers.get(str(c.get("target_item_id", "")))
		if a is Vector2 and b is Vector2:
			var lit := bool(c.get("flow_active", false))
			draw_line(a, b, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.7 if lit else 0.35),
				maxf(1.0, 1.2 * s if s > 0.0 else 1.0))
	# Node chips.
	for k_v in kids:
		var k := k_v as Dictionary
		var col := NODE_BORDER_COLORS.get(str(k.get("type", "")), C_BORDER) as Color
		var chip := Rect2(
			to_mini.call(float(k.get("x", 0.0)), float(k.get("y", 0.0))),
			Vector2(float(k.get("width", 120.0)), float(k.get("height", 90.0))) * s)
		chip = chip.grow(-maxf(0.0, 0.5))
		draw_rect(chip, Color(col.r, col.g, col.b, 0.35), true)
		draw_rect(chip, Color(col.r, col.g, col.b, 0.9), false, 1.0)
	return true


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
	var is_outlet_sink: bool = bool(specs.get("outlet_sink", false))
	var stock_str := ResourceKinds.format_tank_stock(specs)
	var pct_col := UITheme.C_WARN if in_deficit else Color(1, 1, 1, 0.92 if not is_ghost else 0.5)
	# Prefer live stock over ∞ / % so flow is visible in deficit / unlimited modes.
	# Culvert ∞ outlet: always show cumulative_l (not empty % / level×1e12).
	var hub_lbl := stock_str
	if is_outlet_sink:
		hub_lbl = stock_str
	elif in_deficit:
		hub_lbl = ResourceKinds.format_qty(ResourceKinds.tank_stock_qty(specs))
	elif not unlimited and not allow_negative:
		hub_lbl = "%.0f%%" % (level * 100.0)
	draw_string(fnt, Vector2(bar_pos.x + 2.0, bar_pos.y + bar_h * 0.5 + fsize * 0.35),
		hub_lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, pct_col)

	var mode_lbl := ""
	if in_deficit:
		mode_lbl = "Deficit"
	elif allow_negative:
		mode_lbl = "Deficit OK"
	elif unlimited:
		mode_lbl = "∞ cap"
	if not mode_lbl.is_empty():
		draw_string(fnt, Vector2(inner.position.x, bar_pos.y - 3.0),
			"%s · %s" % [mode_lbl, stock_str], HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1,
			UITheme.C_WARN if in_deficit else C_TEXT_M)
	elif not stock_str.is_empty():
		draw_string(fnt, Vector2(inner.position.x, bar_pos.y - 3.0),
			stock_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)

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
	# Site Plan "Ports" toggle — one gate covers every call site; wires are a
	# separate path (site_wire_mode) so they still draw.
	if view_mode == GraphSiteLayout.VIEW_SITE and not site_show_ports:
		return
	var itype   := item.get("type", "generic") as String
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var compound_kind := str(specs.get("compound_kind", "")) if itype == "compound" else ""
	var handles := _resolved_handles(item)
	var hub := GraphHubPorts.is_hub_type(itype)

	# Solar arrays expose one consolidated +/- pair on the bottom edge.
	if compound_kind == "array":
		_draw_array_compound_handles(tl, sz)
		return

	# Generic super-nodes: every promoted port (from specs.exposed_ports, stored
	# on item.handles) is a real, wireable interface — show them ALL, always, so
	# the collapsed node reads as a box with labelled I/O. An empty super-node
	# (no exposures yet) draws no dots rather than the misleading static defaults.
	if itype == "compound" and compound_kind == "":
		var own_handles: Array = item.get("handles", []) as Array
		if own_handles.is_empty():
			return
		for h2: Dictionary in own_handles:
			var pol2 := str(h2.get("polarity", "positive"))
			var rk2 := str(h2.get("resource_kind", ""))
			var rx2 := float(h2.get("rx", 0.0))
			var ry2 := float(h2.get("ry", 0.5))
			_draw_port_dot(tl + Vector2(sz.x * rx2, sz.y * ry2), pol2, rk2)
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
		# Ambient sunlight/wind inputs are documentary — keep them out of the way
		# unless wired or the node is selected (mirrored in the interactive set).
		if is_ambient_doc_handle(itype, hid) and not _ambient_doc_handle_shown(item, hid):
			continue
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


# NOTE: graph_canvas_v2 intentionally OVERRIDES this for the freeform/site billboard
# and calls super() only for the Elevation view — a genuine live polymorphic split
# (both versions run), unlike the other draw methods whose base copies were dead and
# have been consolidated. Kept separate on purpose; edit the elevation path here.
func _draw_port_dot(screen_pos: Vector2, polarity: String, resource_kind: String = "") -> void:
	var touch := _touch_input_active() or DisplayServer.is_touchscreen_available()
	var r   := maxf(5.0, 6.0 * _zoom)
	# Elevation CT: hard screen-space cap — uncapped 6×zoom becomes billboards
	# that drown the pond when zoomed in.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		var s := GraphSiteLayout.px_per_m(_zoom)
		r = clampf(0.28 * s, 2.0, 5.0)
		touch = false
	elif touch:
		r = maxf(r, 9.0)
	var col := _wire_color_for_port(polarity, resource_kind)
	var halo := 1.0 if view_mode == GraphSiteLayout.VIEW_ELEVATION else (3.5 if touch else 1.5)
	var dc := is_dc_polarity(polarity)
	draw_circle(screen_pos, r + halo, Color(col.r, col.g, col.b, 0.35))
	draw_circle(screen_pos, r, dc_port_fill(col, polarity) if dc else col)
	# DC ports read as SOLID discs carrying a + / − glyph; every other port keeps
	# the donut. Punching a background hole through a red and a near-black disc
	# left two thin rings that were hard to tell apart at low zoom.
	if not dc:
		draw_circle(screen_pos, r * 0.45, C_CANVAS_BG)
	draw_circle(screen_pos, r, Color(col.r * 1.15, col.g * 1.15, col.b * 1.15, 0.9), false)
	if dc:
		_draw_polarity_glyph(screen_pos, r, polarity)
	if touch:
		draw_circle(screen_pos, r + 6.0, Color(col.r, col.g, col.b, 0.12), false, 1.5)


static func is_dc_polarity(polarity: String) -> bool:
	return polarity == "positive" or polarity == "negative"


## Disc fill for a DC port. DC− is authored near-black for the WIRE (correct on
## a schematic), but as a filled dot on the dark canvas it vanished and read as
## the same muddy circle as DC+; lift it just enough to separate from the
## background while staying obviously "the black one".
static func dc_port_fill(col: Color, polarity: String) -> Color:
	if polarity == "negative":
		return col.lightened(0.22)
	return col


## The + / − mark inside a DC port dot. Drawn as bars rather than glyphs from a
## font so it stays crisp and centred at every zoom; skipped when the dot is too
## small for the mark to read (Elevation chips).
func _draw_polarity_glyph(center: Vector2, r: float, polarity: String) -> void:
	if r < 4.5:
		return
	var fill := dc_port_fill(_wire_color_for_port(polarity), polarity)
	# Contrast against the disc, not against the canvas.
	var lum := fill.r * 0.299 + fill.g * 0.587 + fill.b * 0.114
	var ink := Color(0.05, 0.06, 0.09, 0.96) if lum > 0.55 else Color(1.0, 1.0, 1.0, 0.94)
	var arm := r * 0.52
	var w := maxf(1.6, r * 0.26)
	draw_line(center - Vector2(arm, 0.0), center + Vector2(arm, 0.0), ink, w)
	if polarity == "positive":
		draw_line(center - Vector2(0.0, arm), center + Vector2(0.0, arm), ink, w)


## Compact pad for elev ports when chips are hidden (true footprint, no 28px floor).
func _elev_port_pad_rect(item: Dictionary, fallback_tl: Vector2, fallback_sz: Vector2) -> Rect2:
	var c := fallback_tl + fallback_sz * 0.5
	var proj: Variant = _phys_project_item_center(item)
	if proj is Vector2:
		c = proj as Vector2
	var fp := GraphSiteLayout.physical_footprint_m(item)
	var s := GraphSiteLayout.px_per_m(_zoom)
	# Keep pads small so they never own the Elevation CT around a turbine.
	var sz := Vector2(
			clampf(maxf(fp.x, fp.y) * s, 5.0, 22.0),
			clampf(maxf(fp.y, 0.6) * s * 0.35, 4.0, 14.0))
	return Rect2(c - sz * 0.5, sz)


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
		hole_o = _disc_origin_screen()
	# Draw each dot as a 2×2 rect, not draw_circle: a radius-1 circle is an
	# antialiased polygon that breaks the 2D batcher, so ~3000 of them each become
	# a separate draw call. Same-color rects batch into far fewer calls and skip the
	# per-dot polygon tessellation — the grid is decorative so the AA loss is nil.
	var dot_sz := Vector2(2.0, 2.0)
	var half   := Vector2(1.0, 1.0)
	var x     := off.x
	while x < size.x:
		var y := off.y
		while y < size.y:
			if hole_r2 <= 0.0 or Vector2(x, y).distance_squared_to(hole_o) > hole_r2:
				draw_rect(Rect2(Vector2(x, y) - half, dot_sz), dot_c)
			y += step
		x += step


## Friendly first-run hint when the graph scope has no nodes, so an empty canvas
## doesn't read as broken. Freeform views only (physical/lab/SoI have their own chrome).
func _draw_empty_state_prompt() -> void:
	var fnt := ThemeDB.fallback_font
	var title := "This canvas is empty"
	var sub := "Open the Library (left panel) and drag a component here to start building your system."
	var c := Vector2(size.x * 0.5, size.y * 0.5)
	var tw := fnt.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, 20).x
	var sw := fnt.get_string_size(sub, HORIZONTAL_ALIGNMENT_CENTER, -1, 13).x
	draw_string(fnt, c - Vector2(tw * 0.5, 6.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
			Color(0.62, 0.70, 0.82, 0.85))
	draw_string(fnt, c - Vector2(sw * 0.5, -18.0), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(0.52, 0.60, 0.72, 0.7))


## Opaque canvas fill everywhere except the SoI disc (live SubViewport shows).
func _draw_canvas_fill_with_soi_hole(fill: Color) -> void:
	var soi_svc := _cached_autoload("/root/SoiService")
	var r_m := 150.0
	if soi_svc != null and soi_svc.has_method("radius_m"):
		r_m = float(soi_svc.call("radius_m"))
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	var origin := _disc_origin_screen()
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
	# GraphSiteLayout.SOI_PX_PER_M). Disc chrome origin must match the live
	# SubViewport (`_disc_origin_screen`) — not size/2+_pan on Elevation.
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	var origin := _disc_origin_screen()

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
		if view_mode == GraphSiteLayout.VIEW_SITE:
			var fnt_site := ThemeDB.fallback_font
			draw_string(fnt_site, origin + Vector2(-r_px + 6.0, -r_px - 6.0),
					"Site Plan · Shift+drag orbit · scroll zoom",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
					Color(0.65, 0.85, 1.0, 0.85))
			# Radial guides only while the projection is still planar top-down
			# (screen-space rings would lie once the 3D orbit takes over).
			if radial_layout_mode and not _phys_camera_projection_active():
				_draw_radial_guides(origin, r_px)
		return

	# Freeform: the ring is a reference marker, independently scalable via
	# Shift+scroll (soi_ring_scale). The old decorative terrain squiggle was a
	# placeholder superseded by the Elevation view — removed.
	var rr := r_px * (soi_ring_scale if view_mode == GraphSiteLayout.VIEW_FREEFORM else 1.0)
	var ring_col2 := Color(0.25, 0.65, 0.95, 0.45)
	draw_circle(origin, rr, Color(0.05, 0.1, 0.15, 0.2))
	draw_arc(origin, rr, 0.0, TAU, 96, ring_col2, maxf(3.0, 6.0 * _zoom), true)
	if view_mode == GraphSiteLayout.VIEW_SITE:
		var fnt2 := ThemeDB.fallback_font
		var wr := site_working_radius_m
		var wr_note := ""
		if not is_nan(wr) and wr > 1.0:
			wr_note = " · R=%.0fm" % wr
		var rad_note := " · Radial" if radial_layout_mode else ""
		draw_string(fnt2, origin + Vector2(-r_px + 6.0, -r_px - 6.0),
				"Site Plan · LMB move 3D · Shift+drag orbit / Shift+drag prop=tangent%s%s"
				% [wr_note, rad_note],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.65, 0.85, 1.0, 0.85))
		if radial_layout_mode or (not is_nan(site_working_radius_m) \
				and site_working_radius_m > 1.0):
			_draw_radial_guides(origin, r_px)
		_draw_site_array_ghosts(origin)


## Faint concentric guide rings + bold working-radius ring (independent of SoI).
func _draw_radial_guides(origin: Vector2, r_px: float) -> void:
	var gc := Color(0.5, 0.8, 1.0, 0.18)
	for f: float in [0.25, 0.5, 0.75]:
		draw_arc(origin, r_px * f, 0.0, TAU, 64, gc, 1.5, true)
	# Faint SoI rim reminder.
	draw_arc(origin, r_px, 0.0, TAU, 96, Color(0.4, 0.7, 0.95, 0.22), 1.25, true)
	var s := GraphSiteLayout.px_per_m(_zoom)
	var wr := site_working_radius_m
	if is_nan(wr) or wr < 1.0:
		wr = r_px / maxf(s, 1e-6)
	var wr_px := wr * s
	if wr_px > 4.0:
		draw_arc(origin, wr_px, 0.0, TAU, 96, Color(0.35, 0.95, 1.0, 0.75), 2.5, true)
	var fnt := ThemeDB.fallback_font
	var msg := "Radial · R=%.0f m · Shift+drag prop = face tangent (SoI rim unchanged)" % wr
	if not radial_layout_mode:
		msg = "Working R=%.0f m · enable Radial for auto-yaw · Shift+drag = tangent" % wr
	draw_string(fnt, origin + Vector2(-r_px + 6.0, r_px + 16.0),
			msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.9, 1.0, 0.85))
	var iid := _item_drag_id if _item_dragging else selected_item_id
	if iid.is_empty() or model == null:
		return
	var it := model.get_item(iid)
	if it.is_empty() or not GraphSiteLayout.has_site_coords(it):
		return
	var site_it := GraphSiteLayout.site_xz(it)
	var rad_px := site_it.length() * s
	if rad_px > 4.0:
		draw_arc(origin, rad_px, 0.0, TAU, 96, Color(0.55, 0.9, 1.0, 0.45), 1.75, true)
		# Radius line from the working center to the item (matches the prop preview).
		draw_line(origin, origin + site_it * s, Color(0.55, 0.9, 1.0, 0.55), 1.5, true)


## Live radial-placement feedback while Shift+dragging a 3D prop in Site Plan: a
## circle centered on the working/radial center through the prop's radius + a radius
## line to the prop. Site Plan is camera-projected (the flat top-down guides don't
## apply once the live disc/orbit is active), so every point is projected through the
## preview camera (world_to_canvas) — the circle correctly reads as an ellipse when
## the view is tilted.
func _draw_prop_radial_preview() -> void:
	if spatial_edit == null or not spatial_edit.has_method("drag_shift_active"):
		return
	if not bool(spatial_edit.call("drag_shift_active")):
		return
	var soi := _cached_autoload("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return
	var center3: Vector3 = soi.call("world_center")
	var cen_site: Vector2 = spatial_edit.call("radial_center_site")
	var prop_site: Vector2 = spatial_edit.call("drag_prop_site")
	var radius := (prop_site - cen_site).length()
	if radius < 0.5:
		return
	var cen_cv = _radial_project_world(center3 + Vector3(cen_site.x, 0.0, cen_site.y))
	var prop_cv = _radial_project_world(center3 + Vector3(prop_site.x, 0.0, prop_site.y))
	if not (cen_cv is Vector2) or not (prop_cv is Vector2):
		return
	var col := Color(0.35, 0.95, 1.0, 0.9)
	# Projected circle (sample world ground points so tilt reads as an ellipse).
	var pts := PackedVector2Array()
	for i in range(73):
		var a := TAU * float(i) / 72.0
		var w := center3 + Vector3(cen_site.x + cos(a) * radius, 0.0, cen_site.y + sin(a) * radius)
		var cv = _radial_project_world(w)
		if cv is Vector2:
			pts.append(cv)
	if pts.size() >= 2:
		draw_polyline(pts, Color(col.r, col.g, col.b, 0.55), 1.75, true)
	draw_line(cen_cv, prop_cv, col, 2.0, true)
	draw_circle(prop_cv, 4.0, col)
	draw_string(ThemeDB.fallback_font, (cen_cv as Vector2) + Vector2(6.0, -6.0),
			"Radial R=%.0f m · tangent" % radius, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


## Project a world point to canvas for the radial overlay: through the preview
## camera when it's the projection authority (Site Plan live disc / orbit), else the
## flat top-down mapping.
func _radial_project_world(world: Vector3) -> Variant:
	if _phys_camera_projection_active() and soi_preview_service != null \
			and is_instance_valid(soi_preview_service) \
			and soi_preview_service.has_method("world_to_canvas"):
		return soi_preview_service.call("world_to_canvas", world)
	var soi := _cached_autoload("/root/SoiService")
	if soi == null or not soi.has_method("world_center"):
		return null
	var c3: Vector3 = soi.call("world_center")
	var site := Vector2(world.x - c3.x, world.z - c3.z)
	return _disc_origin_screen() + site * GraphSiteLayout.px_per_m(_zoom)


## Project a world-XZ point to canvas for the Site Plan NPC overlays (agents,
## spaces, crew sites, desire raster): through the preview camera when it is
## the projection authority — i.e. whenever the live disc is up, which is how
## every other Site Plan element (node chips, elevation overlays) tracks
## orbit/tilt — else the flat top-down mapping. The NPC layers used the flat
## math unconditionally, so orbiting rotated the chips but left the people
## behind. One shared helper so the four layers can't drift again.
## Returns null when the point can't project (skip it).
func _npc_project_site(world_xz: Vector2, center3: Vector3) -> Variant:
	if _phys_camera_projection_active() and soi_preview_service != null \
			and is_instance_valid(soi_preview_service) \
			and soi_preview_service.has_method("world_to_canvas"):
		return soi_preview_service.call("world_to_canvas",
				Vector3(world_xz.x, center3.y, world_xz.y))
	return size * 0.5 + _pan \
			+ GraphSiteLayout.world_xz_to_site(world_xz, center3) \
			* GraphSiteLayout.px_per_m(_zoom)


func _draw_site_array_ghosts(origin: Vector2) -> void:
	if site_array_ghosts.is_empty():
		return
	var s := GraphSiteLayout.px_per_m(_zoom)
	for g in site_array_ghosts:
		if not (g is Dictionary):
			continue
		var site := Vector2(float((g as Dictionary).get("site_x_m", 0.0)),
				float((g as Dictionary).get("site_z_m", 0.0)))
		var p := origin + site * s
		var src := bool((g as Dictionary).get("is_source", false))
		var col := Color(1.0, 0.85, 0.25, 0.9) if src else Color(0.4, 0.95, 1.0, 0.75)
		draw_circle(p, 6.0 if src else 5.0, Color(col.r, col.g, col.b, 0.25))
		draw_circle(p, 6.0 if src else 5.0, col, false, 1.5)
		var yaw := deg_to_rad(float((g as Dictionary).get("yaw_deg", 0.0)))
		# Tick showing outward/tangent facing.
		var tip := p + Vector2(cos(yaw), sin(yaw)) * 12.0
		draw_line(p, tip, col, 1.5)


func _elev_stroke_px(base: float = 2.5) -> float:
	return minf(maxf(2.0, base * _zoom), ELEV_STROKE_MAX_PX)


func _ensure_elev_profile_bake(soi_svc: Node, center3: Vector3, r_m: float,
		r_px: float) -> void:
	var offset := clampf(elevation_section_offset_m, -r_m, r_m)
	# Soft TTL picks up terrain sculpt without forcing DEM every frame.
	var ttl_bucket := int(Time.get_ticks_msec() / 2000)
	# Siphon Lab: denser bake only over the framed along window (tight CT zoom).
	if siphon_lab_active:
		_ensure_elev_anchor()
		var s := GraphSiteLayout.px_per_m(_zoom)
		var half_along := maxf(size.x * 0.55 / maxf(s, 1e-6), 6.0)
		var a0 := _elev_anchor_along_m - half_along
		var a1 := _elev_anchor_along_m + half_along
		var n_lab := ElevationProfile.sample_count_for_lab_window(a1 - a0)
		var key_lab := "lab|%s|%d" % [
			ElevationProfile.cache_key(elevation_heading_rad, offset, a1 - a0,
					n_lab, center3.y),
			ttl_bucket]
		if key_lab == _elev_bake_key and _elev_along.size() == n_lab + 1:
			return
		_elev_bake_key = key_lab
		ElevationProfile.bake_window(soi_svc, center3, elevation_heading_rad, offset,
				a0, a1, n_lab, _elev_along, _elev_y)
		return
	var n := ElevationProfile.sample_count_for_r_px(r_px)
	var key := "%s|%d" % [
		ElevationProfile.cache_key(elevation_heading_rad, offset, r_m, n, center3.y),
		ttl_bucket]
	if key == _elev_bake_key and _elev_along.size() == n + 1:
		return
	_elev_bake_key = key
	ElevationProfile.bake(soi_svc, center3, elevation_heading_rad, offset, r_m, n,
			_elev_along, _elev_y)


func _draw_elevation_section(origin: Vector2, r_px: float, r_m: float, soi_svc: Node) -> void:
	# Contained in the SoI disc. When the 3D section backdrop is live, leave the
	# fill clear so sky / buildings show through. Do NOT draw a canvas ring on
	# top of the live SubViewport disc — that reads as a concentric double circle.
	if not soi_live_preview:
		draw_circle(origin, r_px, Color(0.04, 0.07, 0.12, 0.82))
		var ring_col := Color(0.2, 0.75, 1.0, 0.55)
		draw_arc(origin, r_px, 0.0, TAU, 96, ring_col, _elev_stroke_px(2.5), true)

	var heading_deg := rad_to_deg(elevation_heading_rad)
	var fnt := ThemeDB.fallback_font
	var mode_tag := " · 3D CT" if soi_live_preview else ""
	var ex_label := 1 if (soi_live_preview and _elev_exaggeration_draw() <= 1.001) \
			else int(elevation_exaggeration)
	var lock_note := " · 3D locks 1×" if (soi_live_preview and ex_label == 1) else ""
	var noon_tag := " · solar noon" if soi_live_preview else ""
	# Label just above the disc so it isn't clipped oddly near the rim.
	var ctrl_hint := "drag Prime/Break/water · wheel zoom · side view locked" \
			if siphon_lab_active \
			else "Shift+drag rotate/depth · Shift+wheel zoom"
	draw_string(fnt, origin + Vector2(-r_px + 6.0, -r_px - 6.0),
			"Elevation · %.0f° · slice %+.0fm · %d×%s%s%s  (%s)" % [
				heading_deg, elevation_section_offset_m, ex_label, mode_tag, lock_note,
				noon_tag, ctrl_hint],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.65, 0.85, 1.0, 0.85))

	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var datum := center3.y
	var s := GraphSiteLayout.px_per_m(_zoom)
	var along_dir := Vector2(cos(elevation_heading_rad), sin(elevation_heading_rad))
	var cross_dir := Vector2(-sin(elevation_heading_rad), cos(elevation_heading_rad))
	var offset := clampf(elevation_section_offset_m, -r_m, r_m)
	_ensure_elev_anchor()
	_ensure_elev_profile_bake(soi_svc, center3, r_m, r_px)
	var line_pts := PackedVector2Array()
	var n_pts := mini(_elev_along.size(), _elev_y.size())
	line_pts.resize(n_pts)
	# When orbited, the pond + nodes are placed by the 3D camera; project the
	# terrain profile through the same camera so the pond stays coupled to its
	# depression (otherwise the flat profile drifts off the projected pond).
	var use_proj := _phys_camera_projection_active()
	for i in range(n_pts):
		var along := _elev_along[i]
		var gy := _elev_y[i]
		var site_pt := along_dir * along + cross_dir * offset
		line_pts[i] = _elev_section_to_canvas(site_pt, gy, origin, datum, s,
				along_dir, center3, r_px, use_proj)

	# Horizontal datum chord through the anchored view centre.
	var vc := size * 0.5
	var a_elev := get_elev_anchor_elev_m()
	var datum_y := vc.y - (datum - a_elev) * s * _elev_exaggeration_draw()
	draw_line(Vector2(0.0, datum_y), Vector2(size.x, datum_y),
			Color(1.0, 1.0, 1.0, 0.18), 1.0)

	# Cut-plane cue only when zoomed out enough that the SoI disc fits — at
	# deep Elev CT zoom the old plan-space diameter became a full-screen
	# amber diagonal that looked like a stray PBI/god-ray streak.
	if not soi_live_preview and r_px * 2.0 <= maxf(size.x, size.y) * 1.05:
		var cut_a := origin + along_dir * r_px
		var cut_b := origin - along_dir * r_px
		var cut_mid := origin + cross_dir * (offset / maxf(r_m, 1.0)) * r_px * 0.35
		draw_line(cut_a, cut_b, Color(1.0, 0.85, 0.35, 0.55), _elev_stroke_px(2.0))
		draw_circle(cut_mid, minf(maxf(3.0, 3.5 * _zoom), 8.0),
				Color(1.0, 0.85, 0.35, 0.75))

	if elev_show_dem_overlay and line_pts.size() > 1:
		if not soi_live_preview:
			# Fill under the profile via shared drawer (Siphon Lab uses the same).
			var bl := origin + Vector2(-r_px, r_px)
			var br := origin + Vector2(r_px, r_px)
			ElevationCrossSection.draw_terrain(self, line_pts, bl, br, _elev_stroke_px(2.5))
		else:
			_draw_polyline_stroke(line_pts, ElevationCrossSection.C_TERRAIN_LINE,
					_elev_stroke_px(2.5))

	# Siphon Lab always draws the DEM pond bowl (even if DEM overlay menu is off).
	if siphon_lab_active:
		_lab_level_hits.clear()
		_lab_pond_level_hit.clear()
	if elev_show_dem_overlay or siphon_lab_active:
		_draw_elevation_pond_water_lines(origin, r_px, r_m, datum, s, along_dir, cross_dir,
				offset, soi_svc, center3)
	# Lab: 3D barrel owns the culvert look — skip 2D invert chords (doubles).
	if not siphon_lab_active:
		_draw_elevation_culvert_inverts(origin, r_px, r_m, datum, s, along_dir, cross_dir,
				offset, center3)
	if siphon_lab_active:
		_draw_elevation_siphon_levels(origin, r_px, r_m, datum, s, along_dir, cross_dir,
				offset, center3)
		_draw_elevation_siphon_flow_cues(origin, r_px, r_m, datum, s, along_dir, cross_dir,
				offset, center3)
	# Elev CT: watershed hill scrape is Site Plan / ground only — the teal wedge
	# fights the pond DEM fill and culvert read (Mt. Vernon audit).
	# (Intentionally not drawn here; `_draw_watershed_overlays_site` still runs.)


## Solid blue pond body on Elevation: DEM floor under level_m (matches the
## light-blue terrain contour). Spec floor_m is only a fallback when no bake.
func _draw_elevation_pond_water_lines(origin: Vector2, r_px: float, r_m: float,
		datum: float, s: float, along_dir: Vector2, cross_dir: Vector2,
		slice_offset: float, _soi_svc: Node = null, _center3: Vector3 = Vector3.ZERO) -> void:
	if model == null:
		return
	# Runs inside the _draw cache window (via _draw_soi_background) — _visible_items()
	# reuses the cached root-scope array instead of a fresh full model scan per redraw.
	for it in _visible_items():
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(specs.get("pond_storage", false)):
			continue
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var level_m := float(specs.get("level_m", NAN))
		var rim_m := float(specs.get("rim_m", NAN))
		var floor_m := float(specs.get("floor_m", NAN))
		if is_nan(level_m) and not is_nan(rim_m) and not is_nan(floor_m):
			var span := maxf(rim_m - floor_m, 0.05)
			level_m = floor_m + clampf(float(specs.get("level", 0.5)), 0.0, 1.0) * span
		if is_nan(level_m):
			continue
		if is_nan(floor_m):
			floor_m = level_m - maxf(float(specs.get("depth_m", 1.5)), 0.35)
		if floor_m >= level_m - 0.02:
			floor_m = level_m - 0.35
		var site := GraphSiteLayout.site_xz(item)
		var cross := site.dot(cross_dir)
		# Lab: always draw the bound pond (heading lock may sit slightly off-slice).
		var cross_tol := maxf(r_m * 0.55, 40.0) if siphon_lab_active \
				else maxf(r_m * 0.35, 8.0)
		if absf(cross - slice_offset) > cross_tol:
			continue
		var half_w := _elevation_pond_half_width_m(item, specs, along_dir)
		var pond_along := site.dot(along_dir)
		# Lab: footprint+bank. Free Elev: wider DEM bank search.
		var bank_pad := 2.0 if siphon_lab_active else 4.0
		var search := half_w + bank_pad
		if not siphon_lab_active:
			search = maxf(half_w * 2.5, 60.0)
			search = minf(search, maxf(r_m * 0.95, half_w + 4.0))
		var a0 := pond_along - search
		var a1 := pond_along + search
		# Same projection path as the DEM profile so pond + terrain stay coupled
		# under pan/zoom (camera is synced to elev anchors every pan).
		var use_proj := _phys_camera_projection_active()
		var step_m := 0.35 if siphon_lab_active else 0.75
		var samples := clampi(int(ceili((a1 - a0) / step_m)), 32, 200)
		var alongs := PackedFloat32Array()
		var elevs := PackedFloat32Array()
		alongs.resize(samples + 1)
		elevs.resize(samples + 1)
		for i in range(samples + 1):
			var along := lerpf(a0, a1, float(i) / float(samples))
			var gy := _elev_profile_y_at(along)
			if is_nan(gy):
				gy = floor_m
			alongs[i] = along
			elevs[i] = gy
		# Clamp to the DEM search span (full poly + bank), not footprint half_w —
		# truncating to ±half_w left half the basin dry on large OSM ponds.
		var wet := elev_contiguous_wet_interval(alongs, elevs, level_m, pond_along,
				search)
		var wet_min := wet.x
		var wet_max := wet.y
		if not is_finite(wet_min) or not is_finite(wet_max) or wet_max <= wet_min:
			wet_min = pond_along - half_w
			wet_max = pond_along + half_w
		var floor_pts := PackedVector2Array()
		var prev_along := NAN
		var prev_gy := NAN
		for i in range(samples + 1):
			var along2: float = alongs[i]
			if along2 < wet_min - 0.05 or along2 > wet_max + 0.05:
				prev_along = along2
				prev_gy = elevs[i]
				continue
			var gy2: float = elevs[i]
			if not is_nan(prev_gy) and ((prev_gy < level_m) != (gy2 < level_m)):
				var denom := gy2 - prev_gy
				var t := 0.5 if absf(denom) < 1e-6 \
						else clampf((level_m - prev_gy) / denom, 0.0, 1.0)
				var x_along := lerpf(prev_along, along2, t)
				if x_along >= wet_min - 0.05 and x_along <= wet_max + 0.05:
					var x_site := along_dir * x_along + cross_dir * slice_offset
					floor_pts.append(_elev_section_to_canvas(x_site, level_m,
							origin, datum, s, along_dir, _center3, r_px, use_proj))
			if gy2 < level_m - 0.005:
				var site_pt2 := along_dir * along2 + cross_dir * slice_offset
				floor_pts.append(_elev_section_to_canvas(site_pt2, gy2,
						origin, datum, s, along_dir, _center3, r_px, use_proj))
			prev_along = along2
			prev_gy = gy2
		# DEM miss / dry profile: still show a bowl from specs floor→level.
		if floor_pts.size() < 2:
			floor_pts.clear()
			var n_syn := 8
			for i in range(n_syn + 1):
				var along_s := lerpf(wet_min, wet_max, float(i) / float(n_syn))
				# Gentle U-bowl so banks meet the surface.
				var u := absf((along_s - pond_along) / maxf(half_w, 0.5))
				var gy_s := lerpf(floor_m, level_m - 0.02, clampf(u * u, 0.0, 1.0))
				var site_s := along_dir * along_s + cross_dir * slice_offset
				floor_pts.append(_elev_section_to_canvas(site_s, gy_s,
						origin, datum, s, along_dir, _center3, r_px, use_proj))
		var surf_l := _elev_section_to_canvas(
				along_dir * wet_min + cross_dir * slice_offset, level_m,
				origin, datum, s, along_dir, _center3, r_px, use_proj)
		var surf_r := _elev_section_to_canvas(
				along_dir * wet_max + cross_dir * slice_offset, level_m,
				origin, datum, s, along_dir, _center3, r_px, use_proj)
		var poly := PackedVector2Array()
		poly.append(surf_l)
		poly.append(surf_r)
		for i in range(floor_pts.size() - 1, -1, -1):
			poly.append(floor_pts[i])
		if poly.size() >= 3:
			draw_colored_polygon(poly, Color(0.22, 0.52, 0.92, 0.55))
		# Siphon Lab: fill only (surface is the poly top). Free Elev keeps chords.
		if not siphon_lab_active:
			draw_line(surf_l, surf_r, Color(0.45, 0.85, 1.0, 0.95), _elev_stroke_px(2.5), true)
			if not is_nan(rim_m) and rim_m > level_m + 0.05:
				var rim_pad := maxf(half_w, (wet_max - wet_min) * 0.5) + 2.0
				var rim_l := _elev_section_to_canvas(
						along_dir * (pond_along - rim_pad) + cross_dir * slice_offset, rim_m,
						origin, datum, s, along_dir, _center3, r_px, use_proj)
				var rim_r := _elev_section_to_canvas(
						along_dir * (pond_along + rim_pad) + cross_dir * slice_offset, rim_m,
						origin, datum, s, along_dir, _center3, r_px, use_proj)
				draw_line(rim_l, rim_r, Color(1.0, 0.75, 0.35, 0.55), _elev_stroke_px(1.5))
		else:
			_lab_pond_level_hit = {
				"item_id": str(item.get("id", "")),
				"y_px": (surf_l.y + surf_r.y) * 0.5,
				"x0": minf(surf_l.x, surf_r.x) - 8.0,
				"x1": maxf(surf_l.x, surf_r.x) + 8.0,
				"level_m": level_m,
				"floor_m": floor_m,
				"rim_m": rim_m,
			}


## Contiguous wet interval containing `pond_along` (dry berms split runs).
## Returns Vector2(wet_min, wet_max) or (NAN,NAN).
## `clamp_half` bounds the dry-DEM fallback only — a real wet run is returned
## untruncated so full-basin poly spans paint both banks.
static func elev_contiguous_wet_interval(alongs: PackedFloat32Array,
		elevs: PackedFloat32Array, level_m: float, pond_along: float,
		clamp_half: float) -> Vector2:
	var n := mini(alongs.size(), elevs.size())
	if n < 2:
		return Vector2(NAN, NAN)
	var run_lo := NAN
	var best_lo := NAN
	var best_hi := NAN
	for i in n:
		var wet := elevs[i] < level_m - 0.005
		if wet:
			if is_nan(run_lo):
				run_lo = alongs[i]
			var run_hi: float = alongs[i]
			if pond_along >= run_lo - 0.25 and pond_along <= run_hi + 0.25:
				best_lo = run_lo
				best_hi = run_hi
		else:
			if not is_nan(run_lo):
				var run_hi2: float = alongs[maxi(i - 1, 0)]
				if pond_along >= run_lo - 0.25 and pond_along <= run_hi2 + 0.25:
					best_lo = run_lo
					best_hi = run_hi2
			run_lo = NAN
	if is_nan(best_lo) and not is_nan(run_lo):
		best_lo = run_lo
		best_hi = alongs[n - 1]
	if is_nan(best_lo) or is_nan(best_hi):
		# Footprint / search-span fallback when DEM never went below the waterline.
		return Vector2(pond_along - clamp_half, pond_along + clamp_half)
	if best_hi <= best_lo:
		return Vector2(pond_along - clamp_half, pond_along + clamp_half)
	return Vector2(best_lo, best_hi)


## Interpolate baked Elevation DEM profile at an along-metres coordinate.
func _elev_profile_y_at(along_m: float) -> float:
	var n := mini(_elev_along.size(), _elev_y.size())
	if n <= 0:
		return NAN
	if along_m <= _elev_along[0]:
		return _elev_y[0]
	if along_m >= _elev_along[n - 1]:
		return _elev_y[n - 1]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if _elev_along[mid] <= along_m:
			lo = mid
		else:
			hi = mid
	var a0 := _elev_along[lo]
	var a1 := _elev_along[hi]
	var t := 0.0 if is_equal_approx(a1, a0) else (along_m - a0) / (a1 - a0)
	return lerpf(_elev_y[lo], _elev_y[hi], t)


## Siphon Lab: prime (green) + air-break (red) chords on the shared Elev CT.
func _draw_elevation_siphon_levels(origin: Vector2, r_px: float, r_m: float,
		datum: float, s: float, along_dir: Vector2, cross_dir: Vector2,
		slice_offset: float, center3: Vector3) -> void:
	if model == null:
		return
	var use_proj := _phys_camera_projection_active()
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "siphon_hydro" \
				and str(specs.get("model_id", "")) != "hydroturbine":
			continue
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var site := GraphSiteLayout.site_xz(item)
		var cross := site.dot(cross_dir)
		if absf(cross - slice_offset) > maxf(r_m * 0.35, 12.0):
			continue
		var module_m := float(specs.get("module_elev_m", NAN))
		var start_m := float(specs.get("siphon_start_m", module_m))
		var break_m := float(specs.get("siphon_break_m", module_m))
		if is_nan(start_m) and is_nan(break_m):
			continue
		var half_w := 4.0
		var pond_along := site.dot(along_dir)
		var pond_item := _elev_find_siphon_pond(item)
		if not pond_item.is_empty() and GraphSiteLayout.has_site_coords(pond_item):
			var ps: Dictionary = pond_item.get("specs", {}) as Dictionary
			half_w = _elevation_pond_half_width_m(pond_item, ps, along_dir)
			pond_along = GraphSiteLayout.site_xz(pond_item).dot(along_dir)
		var sid := str(item.get("id", ""))
		if not is_nan(start_m):
			var s0 := _elev_section_to_canvas(
					along_dir * (pond_along - half_w) + cross_dir * slice_offset, start_m,
					origin, datum, s, along_dir, center3, r_px, use_proj)
			var s1 := _elev_section_to_canvas(
					along_dir * (pond_along + half_w) + cross_dir * slice_offset, start_m,
					origin, datum, s, along_dir, center3, r_px, use_proj)
			draw_line(s0, s1, Color(0.35, 0.85, 0.55, 0.85), _elev_stroke_px(2.0), true)
			draw_string(ThemeDB.fallback_font, s1 + Vector2(4, -2), "Prime",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.35, 0.85, 0.55, 0.95))
			_lab_level_hits.append({
				"kind": "prime", "item_id": sid,
				"y_px": (s0.y + s1.y) * 0.5,
				"x0": minf(s0.x, s1.x) - 6.0, "x1": maxf(s0.x, s1.x) + 40.0,
				"elev_m": start_m,
			})
		if not is_nan(break_m):
			var b0 := _elev_section_to_canvas(
					along_dir * (pond_along - half_w) + cross_dir * slice_offset, break_m,
					origin, datum, s, along_dir, center3, r_px, use_proj)
			var b1 := _elev_section_to_canvas(
					along_dir * (pond_along + half_w) + cross_dir * slice_offset, break_m,
					origin, datum, s, along_dir, center3, r_px, use_proj)
			draw_line(b0, b1, Color(0.95, 0.45, 0.35, 0.85), _elev_stroke_px(2.0), true)
			draw_string(ThemeDB.fallback_font, b1 + Vector2(4, 12), "Break",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.95, 0.45, 0.35, 0.95))
			_lab_level_hits.append({
				"kind": "break", "item_id": sid,
				"y_px": (b0.y + b1.y) * 0.5,
				"x0": minf(b0.x, b1.x) - 6.0, "x1": maxf(b0.x, b1.x) + 40.0,
				"elev_m": break_m,
			})


func _elev_find_siphon_pond(siphon: Dictionary) -> Dictionary:
	var sid := str(siphon.get("id", ""))
	if sid.is_empty() or model == null:
		return {}
	for conn in model.connections:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var a := str(c.get("source_item_id", ""))
		var b := str(c.get("target_item_id", ""))
		var other := ""
		if a == sid:
			other = b
		elif b == sid:
			other = a
		else:
			continue
		var tank: Dictionary = model.get_item(other)
		if tank.is_empty():
			continue
		var ts: Dictionary = tank.get("specs", {}) as Dictionary
		if bool(ts.get("pond_storage", false)):
			return tank
	# Nearest pond by site as fallback.
	if not GraphSiteLayout.has_site_coords(siphon):
		return {}
	var sxz := GraphSiteLayout.site_xz(siphon)
	var best: Dictionary = {}
	var best_d := INF
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var ts2: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(ts2.get("pond_storage", false)):
			continue
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var d := GraphSiteLayout.site_xz(item).distance_to(sxz)
		if d < best_d:
			best_d = d
			best = item
	return best


## Map a section point (site metres from SoI centre, absolute elevation) to a
## canvas pixel. Flat path uses metre-space anchors so deep zoom stays precise;
## orbited preview uses world_to_canvas. `origin`/`r_px` kept for API compat
## (disc clamp only when zoomed out enough that the full SoI fits).
func _elev_section_to_canvas(site_pt: Vector2, elev_m: float, origin: Vector2,
		datum: float, s: float, along_dir: Vector2, center3: Vector3,
		r_px: float, use_proj: bool) -> Vector2:
	if use_proj and soi_preview_service != null and is_instance_valid(soi_preview_service):
		var world := Vector3(center3.x + site_pt.x, elev_m, center3.z + site_pt.y)
		var proj: Variant = soi_preview_service.call("world_to_canvas", world)
		if proj is Vector2:
			return proj as Vector2
	_ensure_elev_anchor()
	var along := site_pt.dot(along_dir)
	var vc := size * 0.5
	var a_along := _elev_anchor_along_m
	var a_elev := get_elev_anchor_elev_m()
	var sx := vc.x + (along - a_along) * s
	var sy := vc.y - (elev_m - a_elev) * s * _elev_exaggeration_draw()
	# Soft disc clamp only when the SoI diameter fits on screen (zoomed out).
	if r_px * 2.0 <= maxf(size.x, size.y) * 1.05 and r_px > 8.0:
		sx = clampf(sx, origin.x - r_px, origin.x + r_px)
		sy = clampf(sy, origin.y - r_px, origin.y + r_px)
	return Vector2(sx, sy)


## Half-width along the elevation cut: project pond poly onto `along_dir`.
func _elevation_pond_half_width_m(tank_item: Dictionary, specs: Dictionary,
		along_dir: Vector2 = Vector2(1.0, 0.0)) -> float:
	var tag := str(specs.get("osm_water_tag", ""))
	var half := maxf(float(specs.get("footprint_w_m", 6.0)), 2.0) * 0.5
	half = maxf(half, maxf(float(specs.get("footprint_d_m", 0.0)), 2.0) * 0.5)
	var ad := along_dir
	if ad.length_squared() < 1e-8:
		ad = Vector2(1.0, 0.0)
	else:
		ad = ad.normalized()
	# Prefer live map footprint (world XZ → site) when available.
	var loader := _terrain_loader_node()
	if loader != null and not tag.is_empty() and loader.has_method("find_pond_idx_by_tag"):
		var idx: int = int(loader.call("find_pond_idx_by_tag", tag))
		if idx >= 0 and loader.has_method("get_pond_info"):
			var info: Dictionary = loader.call("get_pond_info", idx) as Dictionary
			var world_poly: PackedVector2Array = info.get("points", PackedVector2Array()) \
					as PackedVector2Array
			if world_poly.size() >= 3:
				var soi_svc := _cached_autoload("/root/SoiService")
				var center3 := Vector3.ZERO
				if soi_svc != null and soi_svc.has_method("world_center"):
					center3 = soi_svc.call("world_center") as Vector3
				var tank_site := GraphSiteLayout.site_xz(tank_item) \
						if GraphSiteLayout.has_site_coords(tank_item) else Vector2.ZERO
				var min_a := INF
				var max_a := -INF
				for wp in world_poly:
					var site_p := GraphSiteLayout.world_xz_to_site(wp, center3) - tank_site
					var a := site_p.dot(ad)
					min_a = minf(min_a, a)
					max_a = maxf(max_a, a)
				if is_finite(min_a) and max_a > min_a:
					half = maxf((max_a - min_a) * 0.5 + 1.0, half)
					return half
	if tag.is_empty() or model == null:
		return half
	for it in model.items:
		if not (it is Dictionary):
			continue
		var other: Dictionary = it
		if str(other.get("type", "")) != "catchment":
			continue
		var os: Dictionary = other.get("specs", {}) as Dictionary
		if str(os.get("osm_water_tag", os.get("osm_tag", ""))) != tag:
			continue
		var poly_v: Variant = os.get("osm_poly_site", null)
		var pts := _osm_poly_site_to_packed(poly_v)
		if pts.size() < 3:
			break
		var min_a2 := INF
		var max_a2 := -INF
		for p in pts:
			var a2 := p.dot(ad)
			min_a2 = minf(min_a2, a2)
			max_a2 = maxf(max_a2, a2)
		if is_finite(min_a2) and max_a2 > min_a2:
			half = maxf((max_a2 - min_a2) * 0.5 + 1.0, half)
		break
	return half


func _osm_poly_site_to_packed(poly_v: Variant) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if poly_v is PackedVector2Array:
		return poly_v as PackedVector2Array
	if not (poly_v is Array):
		return pts
	for p in poly_v as Array:
		if p is Vector2:
			pts.append(p as Vector2)
		elif p is Array and (p as Array).size() >= 2:
			pts.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
	return pts


## True when this item's bound 3D twin exists and is hidden from the 3D world
## (record hidden_3d). Site Plan uses this to suppress the ring for a hidden twin.
## Per-draw memoized by bound_prop_id.
func _item_twin_is_hidden(item: Dictionary) -> bool:
	var pid := str((item.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
	if pid.is_empty():
		return false
	if _twin_hidden_cache.has(pid):
		return bool(_twin_hidden_cache[pid])
	var hidden := false
	var loader := _terrain_loader_node()
	if loader != null and loader.has_method("get_prop_record"):
		var rec: Dictionary = loader.call("get_prop_record", pid) as Dictionary
		hidden = (not rec.is_empty()) and bool(rec.get("hidden_3d", false))
	_twin_hidden_cache[pid] = hidden
	return hidden


func _terrain_loader_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var main := tree.get_first_node_in_group("main_scene")
	if main == null:
		# Resolve by path, not the bare autoload identifier — headless --script
		# selftests run without autoloads and must still compile this file.
		var services := _cached_autoload("/root/Services")
		if services != null:
			main = services.call("get_main") as Node
	if main == null:
		return null
	return main.get_node_or_null("TerrainLoader")


## Site Plan: preview / designated watershed outline (world XZ → disc).
func _draw_watershed_overlays_site() -> void:
	var polys: Array = _watershed_overlay_world_polys()
	if polys.is_empty():
		return
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var s := GraphSiteLayout.px_per_m(_zoom)
	var origin := size * 0.5 + _pan
	var col := Color(0.20, 0.85, 0.78, 0.90)
	var fill := Color(0.15, 0.65, 0.60, 0.16)
	for poly_v in polys:
		if not (poly_v is PackedVector2Array):
			continue
		var poly: PackedVector2Array = poly_v
		if poly.size() < 3:
			continue
		var screen := PackedVector2Array()
		screen.resize(poly.size())
		for i in poly.size():
			var site := GraphSiteLayout.world_xz_to_site(poly[i], center3)
			screen[i] = origin + site * s
		draw_colored_polygon(screen, fill)
		for i in screen.size():
			draw_line(screen[i], screen[(i + 1) % screen.size()], col, 1.75, true)


## Site Plan: live NPC population dots. The view installs a provider Callable
## returning [{pos: Vector2 world XZ, color: Color, activity: String, state}]
## (NpcPopulationEngine.agent_dots); the canvas stays dumb about the sim.
var npc_agents_provider: Callable = Callable()
## Site Plan: player-tagged NPC spaces — [{pos, space_type, label, occupied,
## capacity}] from NpcPopulationBridge.space_markers.
var npc_spaces_provider: Callable = Callable()
## Site Plan active work sites (claimed chores with positions) — see
## NpcPopulationBridge.crew_site_markers.
var npc_crew_provider: Callable = Callable()


## Site Plan: the population's desire lines — a heat raster of where feet
## actually wear paths in. The view installs a provider returning
## {texture: ImageTexture, rect: Rect2 (world XZ), peak, window}.
## ONE draw call: the raster is ~16k cells and per-cell draw_rect would be
## unusable.
var npc_desire_provider: Callable = Callable()
var npc_trails_enabled := true


func _draw_npc_desire_site() -> void:
	if not npc_desire_provider.is_valid():
		return
	var payload: Variant = npc_desire_provider.call()
	if not (payload is Dictionary) or (payload as Dictionary).is_empty():
		return
	var d: Dictionary = payload
	var tex: Texture2D = d.get("texture")
	if tex == null:
		return
	var world: Rect2 = d.get("rect", Rect2())
	if world.size.x <= 0.0 or world.size.y <= 0.0:
		return
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	# All four world corners projected individually: an axis-aligned
	# draw_texture_rect cannot follow the orbited camera, so the raster is a
	# textured quad. Un-orbited the projected corners ARE the old rect.
	var corners_w: Array = [
		world.position,
		Vector2(world.end.x, world.position.y),
		world.end,
		Vector2(world.position.x, world.end.y),
	]
	var pts := PackedVector2Array()
	for cw in corners_w:
		var cv: Variant = _npc_project_site(cw as Vector2, center3)
		if cv == null:
			return  # a corner behind the camera — skip the raster this frame
		pts.append(cv as Vector2)
	var bb := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bb = bb.expand(p)
	if bb.size.x < 1.0 or bb.size.y < 1.0:
		return
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	draw_colored_polygon(pts, Color.WHITE, uvs, tex)
	_draw_npc_desire_legend(d)


## Key for the heat ramp. Without it the colours are just pretty — this says
## what "hot" means, which channel is showing, and how far back it remembers.
func _draw_npc_desire_legend(d: Dictionary) -> void:
	var fnt := ThemeDB.fallback_font
	var pad := 10.0
	var bar_w := 132.0
	var bar_h := 9.0
	# Sits clear of the Unplaced tray along the bottom edge.
	var box := Rect2(pad, size.y - 142.0, bar_w + pad * 2.0, 52.0)
	draw_rect(box, Color(0.04, 0.06, 0.10, 0.82), true)
	draw_rect(box, Color(0.30, 0.38, 0.52, 0.75), false, 1.0)
	var title := "Desire lines · %s" % str(d.get("channel_label", "all traffic"))
	draw_string(fnt, Vector2(box.position.x + pad, box.position.y + 15.0), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.88, 0.91, 0.94, 0.95))
	# The ramp itself, sampled the same way the raster is coloured.
	var bx := box.position.x + pad
	var by := box.position.y + 23.0
	var steps := 44
	for i in steps:
		var t := float(i) / float(steps - 1)
		draw_rect(Rect2(bx + bar_w * t, by, bar_w / float(steps) + 1.0, bar_h),
				NpcDesireMap.heat_color(t), true)
	var foot := "quiet → worn %d m · %s" % [
			int(round(float(d.get("peak", 0.0)))), str(d.get("window", ""))]
	draw_string(fnt, Vector2(bx, by + bar_h + 13.0), foot,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.62, 0.70, 0.80, 0.92))


## Site Plan: where the people are going. A soft disc + ring per tagged space,
## with its glyph and live occupancy, so the destinations behind the agent
## dots are legible.
func _draw_npc_spaces_site() -> void:
	if not npc_spaces_provider.is_valid():
		return
	var marks: Variant = npc_spaces_provider.call()
	if not (marks is Array) or (marks as Array).is_empty():
		return
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var s := GraphSiteLayout.px_per_m(_zoom)
	var fnt := ThemeDB.fallback_font
	# Footprint reads as a ~6 m gathering area, floored so it stays visible
	# when zoomed out to the whole SoI.
	var r := maxf(9.0, 6.0 * s)
	for mark_v in marks as Array:
		if not (mark_v is Dictionary):
			continue
		var mark: Dictionary = mark_v
		var world: Vector2 = mark.get("pos", Vector2.ZERO)
		var screen_v: Variant = _npc_project_site(world, center3)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -60.0 or screen.y < -60.0 or screen.x > size.x + 60.0 or screen.y > size.y + 60.0:
			continue
		var stype := str(mark.get("space_type", ""))
		var col := SpaceTypes.color(stype)
		var occupied := int(mark.get("occupied", 0))
		var capacity := maxi(int(mark.get("capacity", 1)), 1)
		var full := occupied >= capacity
		# An AREA space is a region, not a point — draw the outline the player
		# actually drew, with the marker at its interior point. Without this a
		# 40 m plaza and a single portaloo look identical on the plan.
		var poly: PackedVector2Array = mark.get("poly", PackedVector2Array())
		if poly.size() >= 3:
			var ring := PackedVector2Array()
			var ring_ok := true
			for wp in poly:
				var rv: Variant = _npc_project_site(wp, center3)
				if rv == null:
					ring_ok = false
					break
				ring.append(rv as Vector2)
			if ring_ok:
				draw_colored_polygon(ring, Color(col.r, col.g, col.b, 0.10))
				ring.append(ring[0])
				draw_polyline(ring, Color(col.r, col.g, col.b, 0.7), 1.6, true)
		draw_circle(screen, r, Color(col.r, col.g, col.b, 0.13))
		draw_arc(screen, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.85), 1.8, true)
		# Occupancy sweep on the ring — a full space reads at a glance.
		if occupied > 0:
			var frac := clampf(float(occupied) / float(capacity), 0.0, 1.0)
			draw_arc(screen, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 40,
					Color(1.0, 0.45, 0.35, 0.95) if full else col, 3.2, true)
		if r >= 14.0:
			var glyph := SpaceTypes.icon(stype)
			var fs := 11
			var gw := fnt.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(fnt, screen - Vector2(gw * 0.5, -4.0), glyph,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col.r, col.g, col.b, 0.95))
			var occ := "%d/%d" % [occupied, capacity]
			var ow := fnt.get_string_size(occ, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			draw_string(fnt, screen - Vector2(ow * 0.5, -r - 6.0), occ,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.89, 0.94, 0.9))


## Centre the Site Plan on a WORLD position — the "watch the crew" handoff
## (Linkage Lab queue / deliveries). Bumps the zoom to a people-readable
## scale only when the current one is too far out to show agent dots.
func center_site_on(world_xz: Vector2) -> void:
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	if GraphSiteLayout.px_per_m(_zoom) < 1.2:
		_zoom = clampf(2.2 / GraphSiteLayout.SOI_PX_PER_M, 0.2, 8.0)
	_pan = -GraphSiteLayout.world_xz_to_site(world_xz, center3) \
		* GraphSiteLayout.px_per_m(_zoom)
	queue_redraw()


## Site Plan: active WORK sites — where crews are building right now
## (PACKING_PLAN.md Phase 6.5). Amber disc + tool glyph, drawn under the
## agent dots so the gathered crowd visibly stands ON its work. Sub-quorum
## sites read as a muster ("2/6 ppl" — hands still gathering, work not yet
## paying); quorate sites show the progress sweep instead.
func _draw_npc_crew_sites() -> void:
	if not npc_crew_provider.is_valid():
		return
	var marks: Variant = npc_crew_provider.call()
	if not (marks is Array) or (marks as Array).is_empty():
		return
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var s := GraphSiteLayout.px_per_m(_zoom)
	var fnt := ThemeDB.fallback_font
	var r := maxf(11.0, 4.0 * s)
	var amber := Color(1.0, 0.72, 0.20)
	for mark_v in marks as Array:
		if not (mark_v is Dictionary):
			continue
		var mark: Dictionary = mark_v
		var world: Vector2 = mark.get("pos", Vector2.ZERO)
		var screen_v: Variant = _npc_project_site(world, center3)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -60.0 or screen.y < -60.0 or screen.x > size.x + 60.0 or screen.y > size.y + 60.0:
			continue
		var quorum := bool(mark.get("quorum", true))
		var col := amber if quorum else Color(0.95, 0.55, 0.25)
		# Haul route: the relay line the brigade posts along, drawn before
		# the site disc so the disc caps its end.
		if mark.has("from") and mark.has("to"):
			var fa_v: Variant = _npc_project_site(mark["from"] as Vector2, center3)
			var fb_v: Variant = _npc_project_site(mark["to"] as Vector2, center3)
			if fa_v != null and fb_v != null:
				var fa: Vector2 = fa_v
				var fb: Vector2 = fb_v
				draw_line(fa, fb, Color(col.r, col.g, col.b, 0.55), 2.4, true)
				draw_circle(fa, 4.0, Color(col.r, col.g, col.b, 0.8))
				draw_circle(fb, 4.0, Color(col.r, col.g, col.b, 0.8))
				# The payoff image: items FLOWING along a working brigade line.
				# Phase is sim time (mark.flow_t), so the pips crawl with the
				# clock, freeze on pause, and rewind on a scrub — and redraws
				# already ride the population tick.
				if quorum and str(mark.get("strategy", "")) == "brigade" \
						and float(mark.get("progress", 0.0)) > 0.0 \
						and float(mark.get("progress", 0.0)) < 1.0:
					var pip := maxf(3.0, 1.2 * s)
					var t0 := float(mark.get("flow_t", 0.0)) * 8.0
					for k in 4:
						var f := fposmod(t0 + float(k) / 4.0, 1.0)
						var at := fa.lerp(fb, f)
						draw_rect(Rect2(at - Vector2(pip, pip),
								Vector2(pip * 2.0, pip * 2.0)),
							Color(0.95, 0.72, 0.25, 0.95))
		draw_circle(screen, r, Color(col.r, col.g, col.b, 0.14))
		draw_arc(screen, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.9), 1.8, true)
		if quorum:
			# Work underway: the sweep is the chore's real progress.
			var frac := clampf(float(mark.get("progress", 0.0)), 0.0, 1.0)
			if frac > 0.0:
				draw_arc(screen, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 40,
						Color(0.55, 1.0, 0.45, 0.95), 3.2, true)
		if r >= 11.0:
			var glyph := "🔨"
			var gw := fnt.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(fnt, screen - Vector2(gw * 0.5, -4.0), glyph,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(col.r, col.g, col.b, 0.95))
			var head := str(mark.get("label", ""))
			var crew_txt := "%d/%d ppl — waiting" % [int(mark.get("workers", 0)),
					int(mark.get("min_workers", 1))] if not quorum \
					else "%d ppl" % int(mark.get("workers", 0))
			var lw := fnt.get_string_size(head, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			draw_string(fnt, screen - Vector2(lw * 0.5, r + 16.0), head,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.92, 0.88, 0.78, 0.95))
			var cw := fnt.get_string_size(crew_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			draw_string(fnt, screen - Vector2(cw * 0.5, r + 5.0), crew_txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(col.r, col.g, col.b, 0.95))
	# (Redraws ride the population tick, same as the agent dots.)


func _draw_npc_agents_site() -> void:
	if not npc_agents_provider.is_valid():
		return
	var dots: Variant = npc_agents_provider.call()
	if not (dots is Array) or (dots as Array).is_empty():
		return
	var soi_svc := _cached_autoload("/root/SoiService")
	var center3 := Vector3.ZERO
	if soi_svc != null and soi_svc.has_method("world_center"):
		center3 = soi_svc.call("world_center") as Vector3
	var s := GraphSiteLayout.px_per_m(_zoom)
	# Person-scale dot: ~0.6 m footprint on the plan, but always readable.
	var r := maxf(3.5, 0.35 * s)
	for dot_v in dots as Array:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var world: Vector2 = dot.get("pos", Vector2.ZERO)
		var screen_v: Variant = _npc_project_site(world, center3)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -20.0 or screen.y < -20.0 or screen.x > size.x + 20.0 or screen.y > size.y + 20.0:
			continue
		# Recent trail behind the dot — the aggregate heat map is statistical;
		# this is what makes the view feel alive.
		if npc_trails_enabled:
			var trail: Variant = dot.get("trail", null)
			if trail is PackedVector2Array and (trail as PackedVector2Array).size() >= 2:
				var pts: PackedVector2Array = trail
				var n := pts.size()
				var prev_v: Variant = _npc_project_site(pts[0], center3)
				for i in range(1, n):
					var cur_v: Variant = _npc_project_site(pts[i], center3)
					if prev_v != null and cur_v != null:
						var fade := float(i) / float(n)
						var tc: Color = dot.get("color", Color.WHITE)
						tc.a = fade * 0.5
						draw_line(prev_v as Vector2, cur_v as Vector2, tc,
								maxf(1.0, r * 0.4), true)
					prev_v = cur_v
		# Body = the person's own pastel (identity); rim = their morale band,
		# so the camp's mood is readable at a glance across the whole site.
		var col: Color = dot.get("color", Color.WHITE)
		var mood: Color = dot.get("morale_color", Color(0.6, 0.6, 0.6))
		draw_circle(screen, r + 2.0, Color(0.0, 0.0, 0.0, 0.55))
		draw_circle(screen, r + 1.4, mood)
		draw_circle(screen, r, col)
		# Asleep reads as a dimmer dot; traveling gets a heading tick later.
		if str(dot.get("activity", "")) == "sleep":
			draw_circle(screen, r * 0.55, Color(0.05, 0.08, 0.16, 0.75))
		# Carrying a crate: a small amber square riding the dot — a working
		# haul line reads as dots with items flowing along it (the payoff
		# image PACKING_PLAN Phase 6 names).
		elif bool(dot.get("carrying", false)):
			var hw := maxf(r * 0.55, 2.0)
			draw_rect(Rect2(screen - Vector2(hw, hw), Vector2(hw * 2.0, hw * 2.0)),
					Color(0.95, 0.72, 0.25, 0.95))


## Elevation CT: sample the cut plane through watershed polys (outer-ring verts
## often miss the slice entirely — point-in-poly along the section is reliable).
func _draw_watershed_overlays_elev(origin: Vector2, r_px: float, r_m: float,
		datum: float, s: float, along_dir: Vector2, cross_dir: Vector2,
		slice_offset: float, center3: Vector3) -> void:
	var polys: Array = _watershed_overlay_world_polys()
	if polys.is_empty():
		return
	var use_proj := _phys_camera_projection_active()
	var col := Color(0.20, 0.85, 0.78, 0.95)
	var col_fill := Color(0.12, 0.70, 0.65, 0.28)
	var soi_svc := _cached_autoload("/root/SoiService")
	var step := maxf(r_m / 96.0, 1.5)
	var labeled := false
	for poly_v in polys:
		if not (poly_v is PackedVector2Array):
			continue
		var poly: PackedVector2Array = poly_v
		if poly.size() < 3:
			continue
		var run: PackedVector2Array = PackedVector2Array()
		var a := -r_m
		while a <= r_m + 0.01:
			var site := along_dir * a + cross_dir * slice_offset
			var world := GraphSiteLayout.site_to_world_xz(site, center3)
			var inside := Geometry2D.is_point_in_polygon(world, poly)
			if inside:
				var gy := datum
				if soi_svc != null and soi_svc.has_method("ground_y_at"):
					gy = float(soi_svc.call("ground_y_at", world.x, world.y))
				run.append(_elev_section_to_canvas(site, gy, origin, datum, s,
						along_dir, center3, r_px, use_proj))
			elif run.size() >= 2:
				_draw_polyline_stroke(run, col, _elev_stroke_px(2.8))
				# Soft band under the profile segment.
				for i in range(run.size() - 1):
					var mid := (run[i] + run[i + 1]) * 0.5
					draw_circle(mid, _elev_stroke_px(4.0), col_fill)
				if not labeled:
					var fnt := ThemeDB.fallback_font
					draw_string(fnt, run[0] + Vector2(4.0, -8.0), "Watershed",
							HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
					labeled = true
				run = PackedVector2Array()
			else:
				run = PackedVector2Array()
			a += step
		if run.size() >= 2:
			_draw_polyline_stroke(run, col, _elev_stroke_px(2.8))
			if not labeled:
				var fnt2 := ThemeDB.fallback_font
				draw_string(fnt2, run[0] + Vector2(4.0, -8.0), "Watershed",
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
				labeled = true


## Live TerrainLoader preview only. Designated hillside catchments stay on the
## freeform graph — drawing them here made Site Plan look like a second pond.
func _watershed_overlay_world_polys() -> Array:
	var out: Array = []
	var loader := _terrain_loader_node()
	if loader != null and loader.has_method("get_watershed_preview"):
		var prev: Dictionary = loader.call("get_watershed_preview") as Dictionary
		if bool(prev.get("valid", false)):
			var pw: Variant = prev.get("poly_world", null)
			if pw is PackedVector2Array and (pw as PackedVector2Array).size() >= 3:
				out.append(pw)
	return out


## Straight culvert body in Elevation (replaces sagging resource bezier).
func _draw_elevation_culvert_wire_straight(from: Vector2, to: Vector2, col: Color,
		width: float, flowing: bool, rate: float) -> void:
	var w := maxf(width, 2.0)
	draw_line(from, to, Color(col.r, col.g, col.b, 0.35), w + 3.0, true)
	draw_line(from, to, col, w, true)
	if flowing and rate > 0.01:
		var mid := (from + to) * 0.5
		draw_circle(mid, maxf(3.0, w * 0.6), Color(col.r, col.g, col.b, 0.9))


## Pond→siphon direct intake: short stub + tick at the pond edge (not a full wire).
## Elevation CT: project ConduitManager sample points through world_to_canvas.
## Returns true when the connection was handled (projected or intentionally
## suppressed because 3D pipes own the look).
func _try_draw_elev_conduit_projection(conn: Dictionary, col: Color, width: float,
		flowing: bool, rate: float, res_kind: String) -> bool:
	var want_proj := elev_show_projected_pipes
	if not want_proj and not elev_show_schematic_wires:
		# No schematic + no projected overlay → skip 2D (3D wires if on are
		# the look; if off, draw nothing — do NOT sample every conduit here,
		# that was a G-open hitch / TDR contributor).
		return true
	if not want_proj:
		return false
	var cid := str(conn.get("id", ""))
	if cid.is_empty():
		return false
	var mgr: Node = null
	var parent_v := get_parent()
	while parent_v != null:
		if parent_v.has_method("_get_conduit_manager"):
			mgr = parent_v.call("_get_conduit_manager") as Node
			break
		parent_v = parent_v.get_parent()
	if mgr == null:
		var main := get_tree().current_scene if get_tree() != null else null
		if main != null:
			mgr = main.get_node_or_null("ConduitManager")
	if mgr == null:
		return false
	var samples: PackedVector3Array = PackedVector3Array()
	if mgr.has_method("get_sample_points"):
		samples = mgr.call("get_sample_points", cid) as PackedVector3Array
	if samples.size() < 2 and mgr.has_method("ensure_preview_samples"):
		samples = mgr.call("ensure_preview_samples", conn) as PackedVector3Array
	if samples.size() < 2:
		return false
	if soi_preview_service == null or not is_instance_valid(soi_preview_service):
		return false
	var screen := PackedVector2Array()
	for i in samples.size():
		var proj: Variant = soi_preview_service.call("world_to_canvas", samples[i])
		if proj is Vector2:
			screen.append(proj as Vector2)
	if screen.size() < 2:
		return false
	_draw_polyline_stroke(screen, col, minf(width, ELEV_WIRE_MAX_PX))
	if flowing and rate > 0.01 and _zoom >= WIRE_LABEL_MIN_ZOOM and not res_kind.is_empty():
		_draw_flow_label(screen[0], screen[screen.size() - 1], [], rate, true, res_kind, col)
	return true


func _draw_direct_intake_stub(pond_pos: Vector2, siphon_pos: Vector2, col: Color,
		width: float, flowing: bool, is_sel: bool) -> void:
	var dir := siphon_pos - pond_pos
	var dist := dir.length()
	if dist < 1.0:
		dir = Vector2.RIGHT
		dist = 1.0
	else:
		dir /= dist
	var stub_len := clampf(dist * 0.22, 10.0, 28.0)
	var tip := pond_pos + dir * stub_len
	var w := minf(maxf(width, 2.0), 4.5)
	var stub_col := col if is_sel else Color(col.r, col.g, col.b, 0.85)
	# Dashed stub from pond toward module.
	var segs := 5
	for i in segs:
		if i % 2 == 1:
			continue
		var a := pond_pos.lerp(tip, float(i) / float(segs))
		var b := pond_pos.lerp(tip, float(i + 1) / float(segs))
		draw_line(a, b, stub_col, w, true)
	# Intake tick perpendicular at the pond edge.
	var perp := Vector2(-dir.y, dir.x) * maxf(5.0, w * 2.2)
	draw_line(pond_pos - perp, pond_pos + perp, stub_col, w + 0.5, true)
	draw_circle(pond_pos, maxf(2.5, w * 0.7), stub_col)
	if flowing:
		draw_circle(tip, maxf(2.0, w * 0.55), Color(stub_col.r, stub_col.g, stub_col.b, 0.9))
	draw_string(ThemeDB.fallback_font, tip + Vector2(4, -3), "intake",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			Color(stub_col.r, stub_col.g, stub_col.b, 0.75))


## Culvert invert markers + barrel chord on the elevation section.
func _draw_elevation_culvert_inverts(origin: Vector2, r_px: float, r_m: float,
		datum: float, s: float, along_dir: Vector2, _cross_dir: Vector2,
		_slice_offset: float, center3: Vector3 = Vector3.ZERO) -> void:
	if model == null:
		return
	# Siphon Lab always shows the outlet barrel; otherwise Elev 3D owns the look.
	if not siphon_lab_active and soi_live_preview \
			and not elev_show_schematic_wires and not elev_show_projected_pipes:
		return
	var use_proj := _phys_camera_projection_active()
	# Inside the _draw cache window — reuse the cached visible-connections array.
	for conn in _visible_connections():
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var type_id := ConduitKinds.derive_type_for_connection(c)
		if not ConduitKinds.uses_culvert_kit(type_id):
			continue
		var inv_in := float(c.get("invert_in_m", NAN))
		var inv_out := float(c.get("invert_out_m", NAN))
		if is_nan(inv_in) or is_nan(inv_out):
			continue
		var src := model.get_item(str(c.get("source_item_id", "")))
		var tgt := model.get_item(str(c.get("target_item_id", "")))
		var along0 := 0.0
		var along1 := r_m * 0.35
		if GraphSiteLayout.has_site_coords(src):
			along0 = GraphSiteLayout.site_xz(src).dot(along_dir)
		if GraphSiteLayout.has_site_coords(tgt):
			along1 = GraphSiteLayout.site_xz(tgt).dot(along_dir)
		var p0 := _elev_section_to_canvas(along_dir * along0, inv_in, origin, datum, s,
				along_dir, center3, r_px, use_proj)
		var p1 := _elev_section_to_canvas(along_dir * along1, inv_out, origin, datum, s,
				along_dir, center3, r_px, use_proj)
		var sel := str(c.get("id", "")) == selected_connection_id
		var col := Color(0.95, 0.7, 0.25, 0.95) if sel else Color(0.75, 0.55, 0.2, 0.7)
		draw_line(p0, p1, col, _elev_stroke_px(2.5))
		var mark_r := minf(maxf(4.0, 4.5 * _zoom), 10.0)
		draw_circle(p0, mark_r, col)
		draw_circle(p1, mark_r, col)
		var q := float(c.get("live_q_lps", 0.0))
		if q <= 0.01 and siphon_lab_active:
			# Prefer siphon live Q when the culvert wire hasn't stamped yet.
			var ss: Dictionary = src.get("specs", {}) as Dictionary
			if str(ss.get("role", "")) == "siphon_hydro":
				q = float(ss.get("live_q_lps", 0.0))
		if q > 0.01:
			var mid := (p0 + p1) * 0.5
			draw_string(ThemeDB.fallback_font, mid + Vector2(4, -4),
					"%.1f L/s" % q, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(0.95, 0.85, 0.45, 0.9))
			_draw_elev_outlet_discharge(p0, p1, q)


## Animated chase dashes through the turbine + spray at the culvert outlet.
func _draw_elevation_siphon_flow_cues(origin: Vector2, r_px: float, r_m: float,
		datum: float, s: float, along_dir: Vector2, cross_dir: Vector2,
		slice_offset: float, center3: Vector3) -> void:
	if model == null:
		return
	var use_proj := _phys_camera_projection_active()
	for it in model.items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "siphon_hydro":
			continue
		var q := float(specs.get("live_q_lps", 0.0))
		if q <= 0.02 and not bool(specs.get("siphon_primed", false)):
			continue
		if not GraphSiteLayout.has_site_coords(item):
			continue
		var site := GraphSiteLayout.site_xz(item)
		if absf(site.dot(cross_dir) - slice_offset) > maxf(r_m * 0.4, 14.0):
			continue
		var mod_e := float(specs.get("module_elev_m", item.get("elevation_m", datum)))
		var along := site.dot(along_dir)
		var p_in := _elev_section_to_canvas(
				along_dir * (along - 2.5) + cross_dir * slice_offset, mod_e,
				origin, datum, s, along_dir, center3, r_px, use_proj)
		var p_out := _elev_section_to_canvas(
				along_dir * (along + 2.5) + cross_dir * slice_offset, mod_e,
				origin, datum, s, along_dir, center3, r_px, use_proj)
		var col := Color(0.35, 0.85, 1.0, 0.95) if q > 0.02 \
				else Color(0.55, 0.75, 0.85, 0.55)
		_draw_elev_flow_chase(p_in, p_out, col, q > 0.02)
		if q > 0.02:
			draw_string(ThemeDB.fallback_font, (p_in + p_out) * 0.5 + Vector2(0, -10),
					"turbine %.1f L/s" % q, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
	# Culvert outlet jets (siphon → ∞ sink).
	for conn in model.connections:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		if not ConduitKinds.uses_culvert_kit(ConduitKinds.derive_type_for_connection(c)):
			continue
		var src := model.get_item(str(c.get("source_item_id", "")))
		var tgt := model.get_item(str(c.get("target_item_id", "")))
		if src.is_empty() or tgt.is_empty():
			continue
		var ss: Dictionary = src.get("specs", {}) as Dictionary
		if str(ss.get("role", "")) != "siphon_hydro":
			continue
		var q2 := maxf(float(c.get("live_q_lps", 0.0)), float(ss.get("live_q_lps", 0.0)))
		if q2 <= 0.02:
			continue
		var inv_in := float(c.get("invert_in_m", NAN))
		var inv_out := float(c.get("invert_out_m", NAN))
		if is_nan(inv_in) or is_nan(inv_out):
			continue
		var a0 := GraphSiteLayout.site_xz(src).dot(along_dir) \
				if GraphSiteLayout.has_site_coords(src) else 0.0
		var a1 := GraphSiteLayout.site_xz(tgt).dot(along_dir) \
				if GraphSiteLayout.has_site_coords(tgt) else a0 + 12.0
		var p0 := _elev_section_to_canvas(along_dir * a0, inv_in, origin, datum, s,
				along_dir, center3, r_px, use_proj)
		var p1 := _elev_section_to_canvas(along_dir * a1, inv_out, origin, datum, s,
				along_dir, center3, r_px, use_proj)
		_draw_elev_flow_chase(p0, p1, Color(0.4, 0.8, 1.0, 0.9), true)
		_draw_elev_outlet_discharge(p0, p1, q2)


func _draw_elev_flow_chase(from: Vector2, to: Vector2, col: Color, flowing: bool) -> void:
	var w := _elev_stroke_px(2.2)
	draw_line(from, to, Color(col.r, col.g, col.b, col.a * 0.35), w, true)
	if not flowing:
		return
	var dir := to - from
	var len := dir.length()
	if len < 4.0:
		return
	dir /= len
	var phase := fmod(_flow_phase * 28.0, 14.0)
	var t := phase
	while t < len:
		var a := from + dir * t
		var b := from + dir * minf(t + 6.0, len)
		draw_line(a, b, col, w + 0.5, true)
		t += 14.0


func _draw_elev_outlet_discharge(p0: Vector2, p1: Vector2, q_lps: float) -> void:
	var dir := p1 - p0
	if dir.length_squared() < 1.0:
		dir = Vector2(12.0, 8.0)
	else:
		dir = dir.normalized()
	# Gravity bias on the jet.
	var jet := dir * (18.0 + clampf(q_lps * 2.0, 0.0, 24.0)) + Vector2(0.0, 10.0)
	var tip := p1 + jet
	var col := Color(0.45, 0.85, 1.0, 0.9)
	draw_line(p1, tip, col, _elev_stroke_px(2.8), true)
	# Splash ticks at tip.
	var n := Vector2(-jet.y, jet.x).normalized() * 6.0
	draw_line(tip - n, tip + n, col, _elev_stroke_px(1.6), true)
	draw_circle(tip, 3.5, Color(col.r, col.g, col.b, 0.75))
	draw_string(ThemeDB.fallback_font, tip + Vector2(6, 4), "outlet",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(col.r, col.g, col.b, 0.8))


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
		var tgt_t_out := Vector2(0.0, 1.0)
		if tangents.size() > 0:
			src_t = tangents[0] as Vector2
		if tangents.size() > 1:
			tgt_t_out = tangents[1] as Vector2
		var src_horiz := absf(src_t.x) >= absf(src_t.y)
		var tgt_horiz := absf(tgt_t_out.x) >= absf(tgt_t_out.y)
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
	var r := float(conn.get("_draw_corner_px",
			float(conn.get("corner_radius", 28.0)) * _zoom))
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
	# Elevation deep-zoom uses metre anchors; disc chrome stays viewport-centred.
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		return size * 0.5
	return size * 0.5 + _pan


func _is_physical_view() -> bool:
	return view_mode == GraphSiteLayout.VIEW_SITE \
			or view_mode == GraphSiteLayout.VIEW_ELEVATION


func _item_screen_tl(item: Dictionary, center: Vector2) -> Vector2:
	if _is_physical_view() and GraphSiteLayout.has_site_coords(item):
		var proj: Variant = _phys_project_item_center(item)
		if proj is Vector2:
			return (proj as Vector2) - _item_screen_size(item) * 0.5
	if view_mode == GraphSiteLayout.VIEW_SITE and GraphSiteLayout.has_site_coords(item):
		var c := GraphSiteLayout.site_item_center_screen(
				item, _disc_origin_screen(), _zoom)
		return c - _item_screen_size(item) * 0.5
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
		# Magnifiers are circular — square pad from the longer footprint axis.
		var raw := GraphSiteLayout.site_item_screen_size(item, _zoom)
		var side := maxf(raw.x, raw.y)
		return Vector2(side, side)
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and GraphSiteLayout.has_site_coords(item):
		var fp := GraphSiteLayout.physical_footprint_m(item)
		var s := GraphSiteLayout.px_per_m(_zoom)
		# Floor keeps chips grabbable; cap avoids megapixel chrome at deep zoom.
		return Vector2(
			clampf(maxf(fp.x, fp.y) * s, ELEV_CHIP_MIN_PX, ELEV_CHIP_MAX_PX),
			clampf(maxf(fp.y, 1.0) * s * 0.35, ELEV_CHIP_MIN_H_PX, ELEV_CHIP_MAX_PX * 0.55))
	if view_mode != GraphSiteLayout.VIEW_FREEFORM and not GraphSiteLayout.has_site_coords(item):
		# Tray is screen-space UI — never scale with graph zoom.
		return Vector2(72.0, 36.0)
	return Vector2(float(item.get("width", 120.0)),
		float(item.get("height", 90.0))) * _zoom


## Hit/pick rect — physical views enlarge tiny footprints for usability.
func _item_hit_rect(item: Dictionary) -> Rect2:
	var center := size * 0.5
	# Elev chips-off: compact pad (must run before the generic phys-projection
	# path, which uses inflated chip floors and steals picks from the terrain).
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_chips \
			and GraphSiteLayout.has_site_coords(item):
		var pad := _elev_port_pad_rect(item, Vector2.ZERO, Vector2.ZERO)
		var hit_sz := Vector2(
			maxf(pad.size.x, ELEV_HIT_MIN_PX),
			maxf(pad.size.y, ELEV_HIT_MIN_PX * 0.6))
		return Rect2(pad.get_center() - hit_sz * 0.5, hit_sz)
	if _is_physical_view() and GraphSiteLayout.has_site_coords(item):
		var proj: Variant = _phys_project_item_center(item)
		if proj is Vector2:
			var draw_sz := _item_screen_size(item)
			var hit_sz := Vector2(
				maxf(draw_sz.x, GraphSiteLayout.MIN_SITE_HIT_PX),
				maxf(draw_sz.y, GraphSiteLayout.MIN_SITE_HIT_PX * 0.55))
			return Rect2((proj as Vector2) - hit_sz * 0.5, hit_sz)
	if view_mode == GraphSiteLayout.VIEW_SITE and GraphSiteLayout.has_site_coords(item):
		# Square magnifier hit pad (matches _item_screen_size).
		var c_site := GraphSiteLayout.site_item_center_screen(
				item, _disc_origin_screen(), _zoom)
		var hit_sz := _item_screen_size(item)
		hit_sz = Vector2(
			maxf(hit_sz.x, GraphSiteLayout.MIN_SITE_HIT_PX),
			maxf(hit_sz.y, GraphSiteLayout.MIN_SITE_HIT_PX))
		return Rect2(c_site - hit_sz * 0.5, hit_sz)
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
	_ensure_elev_anchor()
	var s := GraphSiteLayout.px_per_m(_zoom)
	var site := GraphSiteLayout.site_xz(item)
	var along_dir := Vector2(cos(elevation_heading_rad), sin(elevation_heading_rad))
	var elev_m := _elevation_m_for_item(item)
	var datum := _elevation_datum_m()
	var origin := _disc_origin_screen()
	var r_px := _soi_radius_m() * s
	var center3 := Vector3(0.0, datum, 0.0)
	var soi := _cached_autoload("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		center3 = soi.call("world_center") as Vector3
	var use_proj := _phys_camera_projection_active()
	var c := _elev_section_to_canvas(site, elev_m, origin, datum, s, along_dir,
			center3, r_px, use_proj)
	var sz := _item_screen_size(item)
	return c - sz * 0.5


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
	var label := "Unplaced (%d) — drop onto SoI disc (wires show once placed)" % list.size() \
		if list.size() > 0 else "Unplaced (0)"
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
		# Empty-site onboarding: nothing placed yet — say what this view is
		# for, centered on the disc where the eye lands first.
		var placed := 0
		for item: Dictionary in _visible_items():
			if GraphSiteLayout.has_site_coords(item):
				placed += 1
		if placed == 0:
			var hint1 := "Nothing is placed on the site yet"
			var hint2 := "Drag a chip from the tray below onto the disc — its position maps to the 3D world"
			var f2 := ThemeDB.fallback_font
			var w1 := f2.get_string_size(hint1, HORIZONTAL_ALIGNMENT_CENTER, -1, 15).x
			var w2 := f2.get_string_size(hint2, HORIZONTAL_ALIGNMENT_CENTER, -1, 12).x
			draw_string(f2, origin + Vector2(-w1 * 0.5, -6.0), hint1,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.93, 1.0, 0.9))
			draw_string(f2, origin + Vector2(-w2 * 0.5, 16.0), hint2,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.78, 0.95, 0.75))


## Graph-space disc matching `_draw_soi_background` (origin + radius_px).
func get_soi_disc_layout() -> Dictionary:
	var soi_svc := _cached_autoload("/root/SoiService")
	var r_m := 150.0
	if soi_svc != null and soi_svc.has_method("radius_m"):
		r_m = float(soi_svc.call("radius_m"))
	var r_px := r_m * GraphSiteLayout.SOI_PX_PER_M * _zoom
	var origin := size * 0.5 if view_mode == GraphSiteLayout.VIEW_ELEVATION \
			else size * 0.5 + _pan
	return {
		"origin": origin,
		"radius_px": r_px,
		"radius_m": r_m,
	}


## Site Plan magnifier: transparent circular ring over the 3D twin.
func _draw_site_magnifier(item: Dictionary, rect: Rect2, is_sel: bool) -> void:
	var itype := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var iid := str(item.get("id", ""))
	var is_hover := iid == _site_hover_item_id and not iid.is_empty()
	var is_drag := _item_dragging and (
			iid == _item_drag_id or _item_drag_ids.has(iid))
	var border := NODE_BORDER_COLORS.get(itype, C_BORDER) as Color
	if is_sel or is_drag:
		border = C_SELECTED_BORDER
	elif not str(specs.get("osm_tag", "")).is_empty():
		if itype == "catchment":
			if str(specs.get("catchment_kind", "")) == "watershed":
				border = Color(0.25, 0.82, 0.72, 1.0)
			else:
				border = Color(1.0, 0.72, 0.18, 1.0)
		elif itype == "plant":
			border = Color(0.35, 0.85, 0.42, 1.0)
	var c := rect.get_center()
	# True footprint / OSM poly under the ring (ground truth, not opaque chrome).
	_draw_true_footprint_outline(item, c, border)
	_draw_osm_site_poly(item, c, border, is_sel)
	var side := maxf(minf(rect.size.x, rect.size.y), GraphSiteLayout.MIN_SITE_HIT_PX)
	var r := maxf(side * 0.5, 0.5)
	# Keep the open aperture large — thin stroke so the 3D twin reads through.
	var stroke := clampf(r * 0.08, 1.25, maxf(1.75, 2.25 * _zoom))
	if is_sel or is_drag:
		stroke = maxf(stroke, 2.0)
	# Soft outer halo for hover / selection / drag feedback.
	if is_sel or is_hover or is_drag:
		var halo_a := 0.40 if (is_sel or is_drag) else 0.26
		var halo_r := r + stroke * 2.0
		draw_arc(c, halo_r, 0.0, TAU, 40,
				Color(border.r, border.g, border.b, halo_a), maxf(1.25, stroke * 0.9), true)
	# No opaque fill — aperture stays clear for the SoI 3D model.
	draw_arc(c, r, 0.0, TAU, 40, border, stroke, true)
	# Inner lip only when the ring is large enough to keep a clear center.
	if r >= 18.0:
		var inner_r := maxf(r - stroke * 1.4, r * 0.82)
		draw_arc(c, inner_r, 0.0, TAU, 36,
				Color(border.r, border.g, border.b, 0.30 if is_sel else 0.18),
				maxf(0.9, stroke * 0.4), true)
	# Labels: toggle + selected/drag, or large enough to not plug the aperture.
	if (site_show_chips and r >= 22.0) or is_sel or is_drag:
		var title := _site_plan_chip_title(item, specs, itype)
		_draw_site_plan_chip_label(rect, title, is_sel or is_drag)


func _draw_site_plan_chip(item: Dictionary, rect: Rect2, is_sel: bool) -> void:
	if view_mode == GraphSiteLayout.VIEW_ELEVATION and not elev_show_chips:
		return
	var itype := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var border := NODE_BORDER_COLORS.get(itype, C_BORDER) as Color
	if is_sel:
		border = C_SELECTED_BORDER
	# OSM imports: amber roof / green field highlight matching world outlines.
	# Watershed hillside catchments use teal so they read apart from roof rain.
	if not str(specs.get("osm_tag", "")).is_empty():
		if itype == "catchment":
			if str(specs.get("catchment_kind", "")) == "watershed":
				border = Color(0.25, 0.82, 0.72, 1.0) if not is_sel else C_SELECTED_BORDER
			else:
				border = Color(1.0, 0.72, 0.18, 1.0) if not is_sel else C_SELECTED_BORDER
		elif itype == "plant":
			border = Color(0.35, 0.85, 0.42, 1.0) if not is_sel else C_SELECTED_BORDER
	# Physical-subject (has model_id): transparent chrome so the SoI 3D model shows.
	var see_through := not str(specs.get("model_id", "")).is_empty() \
			and GraphSiteLayout.has_site_coords(item)
	var fill := Color(0.09, 0.14, 0.22, 0.92)
	if see_through:
		fill = Color(0.09, 0.14, 0.22, 0.08 if is_sel else 0.0)
	var min_side := minf(rect.size.x, rect.size.y)
	# Stroke scales with footprint so a 2 px panel isn't buried under a 4 px border.
	var stroke := clampf(min_side * 0.12, 0.75, maxf(1.25, 2.0 * _zoom))
	if view_mode == GraphSiteLayout.VIEW_ELEVATION:
		stroke = minf(stroke, ELEV_STROKE_MAX_PX)
	var c := rect.get_center()
	# True physical outline (1 px) when chip is scaled up beyond footprint.
	_draw_true_footprint_outline(item, c, border)
	# OSM polygon is a plan footprint — never draw it in Elevation (confusing
	# floating outline). Site plan keeps the true poly chip.
	if view_mode != GraphSiteLayout.VIEW_ELEVATION \
			and _draw_osm_site_poly(item, c, border, is_sel):
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
	if GraphSiteLayout.uses_circular_plan_chip(item, view_mode):
		var r := maxf(min_side * 0.5, 0.5)
		if fill.a > 0.01:
			draw_circle(c, r, fill)
		draw_arc(c, r, 0.0, TAU, 32, border, stroke, true)
	else:
		if fill.a > 0.01:
			draw_rect(rect, fill, true)
		draw_rect(rect, border, false, stroke)
		# Solar-array packs: light module grid so the footprint reads as panels.
		if not see_through and itype == "compound" \
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
	if GraphSiteLayout.uses_circular_plan_chip(item, view_mode):
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

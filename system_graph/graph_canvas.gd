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
	"wind":         Color(0.360, 0.840, 0.780, 1.0),  # teal — wind turbine
	"hydro":        Color(0.250, 0.620, 0.950, 1.0),  # water blue — hydro turbine
	"catchment":    Color(0.200, 0.550, 0.900, 1.0),
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
	"wind":          [160, 138],
	"hydro":         [160, 138],
	"catchment":     [140, 112],
}
const NODE_SIZE_DEFAULT := [158, 118]

# Handle definitions by type: Array of {id, polarity, rx, ry}
# rx/ry are fractional positions (0-1) relative to node width/height
const HANDLES := {
	"panel": [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
	],
	# Wind/hydro generators wire like panels: DC out the bottom into a
	# controller PV input or a combiner.
	"wind": [
		{"id": "positive", "polarity": "positive", "rx": 0.67, "ry": 1.0},
		{"id": "negative", "polarity": "negative", "rx": 0.33, "ry": 1.0},
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
		{"id": "output", "polarity": "resource", "resource_kind": "water", "rx": 0.5, "ry": 1.0},
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
}

# ---------------------------------------------------------------------------
# Pan / zoom
# ---------------------------------------------------------------------------
const ZOOM_MIN       := 0.25
const ZOOM_MAX       := 4.0
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

var _pan:            Vector2 = Vector2.ZERO
var _zoom:           float   = 1.0
var _dragging:       bool    = false
var _last_drag_pos:  Vector2 = Vector2.ZERO
var _pan_button:     int     = -1
var pan_right_mouse: bool    = true

# ---------------------------------------------------------------------------
# Item drag
# ---------------------------------------------------------------------------
var _item_dragging:       bool    = false
var _item_drag_id:        String  = ""
var _item_drag_start_px:  Vector2 = Vector2.ZERO
var _item_drag_start_pos: Vector2 = Vector2.ZERO
const DRAG_THRESHOLD := 4.0
const TOUCH_DRAG_THRESHOLD := 10.0
const TOUCH_PORT_GRAB_MIN := 18.0
const TOUCH_SNAP_RADIUS_MIN := 36.0
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
var _marquee_selecting:     bool = false
var _marquee_start:         Vector2 = Vector2.ZERO
var _marquee_end:           Vector2 = Vector2.ZERO
## Screen-space hit rects for destroyed-controller Reset buttons (cleared each draw).
var _controller_reset_rects: Dictionary = {}
## Short-lived smoke puffs when a controller is destroyed: {item_id, center, age}.
var _destroy_fx: Array = []
var _needs_continuous_redraw: bool = false

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

# ---------------------------------------------------------------------------
# External references (set by SystemGraphView)
# ---------------------------------------------------------------------------
var model:        GraphModel = null
## True when inverter AC output is shed (low SOC / overload lockout).
var _ac_shed_active: bool = false
## "build" or "test" — set by SystemGraphView when mode toggle changes.
var current_mode: String     = "build"
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
	_redraw_accum += delta
	var interval := REDRAW_INTERVAL if (current_mode == "test" or _needs_continuous_redraw or fx_alive) else 0.25
	if _redraw_accum >= interval:
		_redraw_accum = 0.0
		queue_redraw()
		if current_mode != "test" and not fx_alive:
			_needs_continuous_redraw = false


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

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
				or _waypoint_dragging or _ortho_seg_dragging:
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
		if _touch_positions.is_empty():
			_touch_interaction = ""
		accept_event()


func _handle_screen_drag(sd: InputEventScreenDrag) -> void:
	_touch_positions[sd.index] = sd.position
	if _touch_pan_active and _touch_interaction == "pan" and _touch_positions.size() >= 2:
		var mid := _touch_positions_midpoint()
		_pan += mid - _touch_pan_last_mid
		_touch_pan_last_mid = mid
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


func _cancel_pointer_interaction() -> void:
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
				wps[_waypoint_drag_idx] = _screen_to_graph(screen_pos)
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
	var world := (screen_pos - center - _pan) / old_zoom
	_pan = screen_pos - center - world * _zoom
	queue_redraw()


func _scope_of_item(item: Dictionary) -> String:
	return str(item.get("scope_id", "root"))


func _scope_of_conn(conn: Dictionary) -> String:
	return str(conn.get("scope_id", "root"))


func _visible_items() -> Array:
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
	if model == null:
		return []
	if model.has_method("get_connections_in_scope"):
		return model.get_connections_in_scope(active_scope_id)
	var out: Array = []
	for conn: Dictionary in model.connections:
		if _scope_of_conn(conn) == active_scope_id:
			out.append(conn)
	return out


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
		if rr.has_point(screen_pos):
			controller_reset_pressed.emit(str(rid))
			return
	_marquee_selecting = false
	var wp_hit := _waypoint_hit(screen_pos)
	if not wp_hit.is_empty():
		_waypoint_dragging = true
		_waypoint_drag_conn = str(wp_hit.get("conn_id", ""))
		_waypoint_drag_idx = int(wp_hit.get("index", -1))
		_touch_interaction = "waypoint"
		return
	var ortho_hit := _ortho_segment_hit(screen_pos)
	if not ortho_hit.is_empty():
		_begin_ortho_segment_drag(ortho_hit, screen_pos)
		return
	var hit := _item_at_screen(screen_pos)
	var touch_rules := _touch_input_active() or DisplayServer.is_touchscreen_available()

	# On touch, the node body interior wins over nearby port grab rings so
	# small load nodes remain draggable without accidentally starting wires.
	if touch_rules and not hit.is_empty() and _touch_point_in_item_body(screen_pos, hit):
		_begin_item_press(screen_pos, hit)
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
	_item_drag_id        = hit_id
	_item_drag_start_px  = screen_pos
	_item_drag_ids.clear()
	_item_drag_start_map.clear()
	if not selected_item_ids.has(hit_id):
		selected_item_ids.clear()
		selected_item_ids.append(hit_id)
	_item_drag_ids = selected_item_ids.duplicate()
	for iid: String in _item_drag_ids:
		var it := model.get_item(iid)
		if it.is_empty():
			continue
		_item_drag_start_map[iid] = Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0)))
	_item_drag_start_pos = _item_drag_start_map.get(hit_id, Vector2(float(hit.get("x", 0.0)), float(hit.get("y", 0.0))))
	_touch_interaction = "item"
	_select_item(hit_id)


func _touch_point_in_item_body(screen_pos: Vector2, item: Dictionary) -> bool:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
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
			var center := size * 0.5
			var hits: Array[String] = []
			for item: Dictionary in _visible_items():
				var tl := _item_screen_tl(item, center)
				var sz := _item_screen_size(item)
				var ir := Rect2(tl, sz)
				if rect.intersects(ir):
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
				_select_item("")
		return

	# Click on background — check wires, then deselect
	if _item_at_screen(screen_pos).is_empty():
		var conn := _connection_at_screen(screen_pos)
		if not conn.is_empty():
			_select_connection(conn.get("id", "") as String)
		else:
			_select_item("")


# Item drag move
func _on_item_drag_move(screen_pos: Vector2) -> void:
	if model == null or _item_drag_id.is_empty():
		return
	var delta_px  := screen_pos - _item_drag_start_px
	var delta_gr  := delta_px / _zoom
	for iid: String in _item_drag_ids:
		var start_pos: Vector2 = _item_drag_start_map.get(iid, Vector2.ZERO) as Vector2
		var new_pos := start_pos + delta_gr
		model.update_item(iid, {"x": new_pos.x, "y": new_pos.y})
	queue_redraw()


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
	if d_cap <= 0.0 and t_cap <= 0.0:
		return false
	var d_lvl := clampf(float(d_specs.get("level", 0.0)), 0.0, 1.0)
	var t_lvl := clampf(float(t_specs.get("level", 0.0)), 0.0, 1.0)
	var new_cap := d_cap + t_cap
	var new_lvl := (d_cap * d_lvl + t_cap * t_lvl) / new_cap if new_cap > 0.001 else 0.0
	var target_id := str(target.get("id", ""))
	var unit := str(t_specs.get("capacity_unit", ResourceKinds.default_unit(t_kind)))
	t_specs["capacity_qty"] = new_cap
	t_specs["level"] = clampf(new_lvl, 0.0, 1.0)
	t_specs["capacity"] = "%.0f %s" % [new_cap, unit] if unit in ["L", "kg"] else "%.1f %s" % [new_cap, unit]
	var t_name := str(t_specs.get("name", "Tank"))
	if not t_name.contains("merged"):
		t_specs["name"] = "%s (merged)" % t_name
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
	var center := size * 0.5
	var vis := _visible_items()
	for i in range(vis.size() - 1, -1, -1):
		var item: Dictionary = vis[i]
		if str(item.get("id", "")) == exclude_id:
			continue
		var tl := _item_screen_tl(item, center)
		var sz := _item_screen_size(item)
		if Rect2(tl, sz).has_point(screen_pos):
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
	var center := size * 0.5
	# Iterate in reverse so topmost (last drawn) is hit first
	var vis := _visible_items()
	for i in range(vis.size() - 1, -1, -1):
		var item: Dictionary = vis[i]
		var tl := _item_screen_tl(item, center)
		var sz := _item_screen_size(item)
		if Rect2(tl, sz).has_point(screen_pos):
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
			if ResourceKinds.kinds_compatible(_wire_src_resource_kind, drop_kind):
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
		# Drop-to-body only on resource tanks (catchments are sources, not sinks).
		if str(item.get("type", "")) != "resource":
			continue
		var tl := _item_screen_tl(item, center)
		var sz := _item_screen_size(item)
		if not GraphHubPorts.point_in_hub_body(tl, sz, screen_pos):
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var kind := ""
		if str(item.get("type", "")) == "catchment":
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
		"line_style":       "bezier",
		"curve_tension":    1.0,
		"corner_radius":    28.0,
		"voltage_mismatch": false,
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
		"line_style":       "bezier",
		"curve_tension":    1.0,
		"corner_radius":    28.0,
		"voltage_mismatch": false,
	})
	_wire_hub_drop = {}
	layout_changed.emit()
	queue_redraw()


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
		if primary.has(hid) or wired.has(hid):
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


## True when src and tgt polarities form a valid connection.
func _polarity_compatible(src: String, tgt: String,
		src_kind: String = "", tgt_kind: String = "") -> bool:
	if src == "resource" and tgt == "resource":
		return ResourceKinds.kinds_compatible(src_kind, tgt_kind)
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
	if not _wire_snap.is_empty() and not _wire_snap_valid:
		col = C_RED
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
		var ring_col := C_GREEN if _wire_snap_valid else C_RED
		draw_circle(snap_pos, 10.0 * _zoom, Color(ring_col.r, ring_col.g, ring_col.b, 0.25))
		draw_circle(snap_pos, 9.0  * _zoom, ring_col, false)
		if not _wire_snap_valid and _wire_src_polarity == "resource":
			var msg := ResourceKinds.mismatch_message(
				_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
			var fnt := ThemeDB.fallback_font
			draw_string(fnt, snap_pos + Vector2(12.0, -8.0), msg,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.98, 0.45, 0.42, 0.95))


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
	var apb := get_node_or_null("/root/AcPowerBus")
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
	for conn: Dictionary in _visible_connections():
		_render_connection(conn, center, solar_w, load_w)


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
		if style == "orthogonal":
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
	if style == "orthogonal":
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
	# Ghost track (route visible when idle)
	_draw_bezier_stroke(from, c1, c2, to, 24,
		Color(col.r, col.g, col.b, col.a * 0.20), maxf(1.4, width * 0.65))
	if flow_active and gscale > 0.01:
		var glow_a := 0.07 + 0.13 * gscale
		_draw_bezier_stroke(from, c1, c2, to, 28,
			Color(col.r, col.g, col.b, glow_a), body_w + 2.2 + 2.4 * gscale)
	var core := Color(
		lerpf(col.r, 1.0, 0.14 * gscale),
		lerpf(col.g, 1.0, 0.12 * gscale),
		lerpf(col.b, 1.0, 0.08 * gscale),
		lerpf(col.a, 1.0, 0.12 * gscale))
	_draw_bezier_stroke(from, c1, c2, to, 30, core, maxf(1.6, body_w))
	if flow_active:
		ResourceEdgeVis.draw_bezier_flow_cues(
			self, from, c1, c2, to, col, body_w, _flow_phase, reverse_chase)


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

	# 1) Glow halo — 5 concentric passes, innermost brightest
	if flow_active and flow_watts > WIRE_FLOW_FLOOR * 0.5:
		for p in 5:
			var layer:  float  = float(p) / 4.0
			# Outer passes are wider but more transparent; inner close to the wire body
			var gw: float = width + 1.5 + (extra) * (1.0 - layer * 0.55)
			var a_g:  float  = (0.15 - layer * 0.025) * gscale
			_draw_bezier_stroke(from, c1, c2, to, 28, Color(col.r, col.g, col.b, a_g), gw)
		# Extra tight inner halo at near-white to create a bright core
		var inner_w: float = width * 0.9
		var inner_a: float = 0.22 * gscale
		_draw_bezier_stroke(from, c1, c2, to, 34,
			Color(lerpf(col.r, 1.0, 0.5), lerpf(col.g, 1.0, 0.5), lerpf(col.b, 1.0, 0.5), inner_a),
			inner_w)

	# 2) Main body — slightly whitened core at high power
	var core := Color(
		lerpf(col.r, 1.0, 0.18 * gscale),
		lerpf(col.g, 1.0, 0.15 * gscale),
		lerpf(col.b, 1.0, 0.12 * gscale),
		body_alpha)
	_draw_bezier_stroke(from, c1, c2, to, 34, core, maxf(1.2, width))

	# 3) Chase: bright head + thin trail along the line
	# Chase count scales with power level and timescale so high-speed sim is still readable.
	if flow_active:
		var extra_dots := int(gscale * 3.0) + int(clampf(log(_sim_flow_mult + 1.0) * 1.2, 0.0, 4.0))
		var chase_count := WIRE_CHASE_COUNT + extra_dots
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
	var extra_dots := int(gscale * 3.0) + int(clampf(log(_sim_flow_mult + 1.0) * 1.2, 0.0, 4.0))
	var chase_count := WIRE_CHASE_COUNT + extra_dots
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
	var extra_dots := int(gscale * 2.0) + int(clampf(log(_sim_flow_mult + 1.0), 0.0, 3.0))
	var chase_count := WIRE_CHASE_COUNT + extra_dots
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


func _draw_connection_waypoint_handles(conn: Dictionary, center: Vector2) -> void:
	if str(conn.get("id", "")) != selected_connection_id:
		return
	for wp: Vector2 in _waypoints_screen(conn, center):
		var r := maxf(5.0, 6.0 * _zoom)
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
	var wps: Array = _waypoints_screen(conn, center)
	var pick_r := maxf(10.0, 12.0 * _zoom)
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
	if conn.is_empty() or str(conn.get("line_style", "bezier")) != "orthogonal":
		return {}
	var center := size * 0.5
	var poly := _connection_polyline_screen(conn, center, false)
	if poly.size() < 2:
		return {}
	const PICK_DIST := 10.0
	var best_idx := -1
	var best_dist := PICK_DIST
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

## Alpha for the canvas background — driven by the graph view transparency slider.
var canvas_bg_alpha: float = 1.0

func _draw() -> void:
	_controller_reset_rects.clear()
	draw_rect(Rect2(Vector2.ZERO, size), Color(C_CANVAS_BG.r, C_CANVAS_BG.g, C_CANVAS_BG.b, C_CANVAS_BG.a * canvas_bg_alpha))
	_draw_dot_grid()

	if model != null and _visible_items().size() > 0:
		_draw_connections()
		for item: Dictionary in _visible_items():
			_render_item(item)
		for item: Dictionary in _visible_items():
			_draw_item_overlays(item)

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
		var fs := maxi(7, int(round(12.0 * _zoom)))
		draw_string(fnt, tl + Vector2(3.0 * _zoom, float(fs) + 2.0 * _zoom),
			"⚙", HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.85))

	if _item_flash.has(iid):
		var t := clampf(float(_item_flash[iid]) / ITEM_FLASH_SECONDS, 0.0, 1.0)
		var pulse := 0.35 + 0.65 * absf(sin(t * PI * 3.0))
		draw_rect(Rect2(tl, sz).grow(3.0 * _zoom),
			Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.75 * t * pulse),
			false, maxf(1.5, 3.0 * _zoom))


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

	if itype in ["battery", "smartbattery", "resource"]:
		var level: float = clampf(float(specs.get("soc", specs.get("level", 0.0))), 0.0, 1.0)
		var scale_factor = 1.0 + (level * 0.15)
		sz = sz_orig * scale_factor
		tl = tl_orig - (sz - sz_orig) * 0.5
		
	var rect    := Rect2(tl, sz)

	if itype in ["battery", "smartbattery", "resource"]:
		var level: float = clampf(float(specs.get("soc", specs.get("level", 0.0))), 0.0, 1.0)
		var alert_threshold = float(specs.get("alert_threshold_pct", 95.0)) / 100.0
		if level >= alert_threshold:
			var wave_count = 3
			for w in wave_count:
				var wave_phase = fmod(_flow_phase * 1.5 + float(w) / wave_count, 1.0)
				var wave_expand = maxf(5.0, 30.0 * _zoom) * wave_phase
				var wave_rect = rect.grow(wave_expand)
				var alpha = (1.0 - wave_phase) * 0.6
				draw_rect(wave_rect, Color(1.0, 0.2, 0.2, alpha), false, 2.0 * _zoom)

	# Active load highlight / blocked vibration (behind frame)
	if itype in ["appliance", "acload", "processor"]:
		var st := str(specs.get("current_state", "")).to_lower()
		var avg := float(specs.get("avg_watts", 0.0))
		var tries_to_run = (st == "on" or (st.is_empty() and avg > 0.5))
		var is_starved = bool(specs.get("is_starved", false))
		if tries_to_run:
			if is_starved:
				var offset = Vector2(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0)) * _zoom
				tl += offset
				rect.position += offset
				var glow := rect.grow(maxf(2.5, 3.0 * _zoom))
				draw_rect(glow, Color(0.9, 0.15, 0.2, 0.35), true)
			else:
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
		"shelly4pm":
			_draw_shelly4pm_body(body_rect, specs)
		_:
			_draw_generic_body(body_rect, specs)

	# Live / Sim data-source badge — shows whether the wattage / soc / state
	# currently displayed comes from real HA pushes or from the in-game
	# simulation.  Only meaningful for data-bearing node types.
	if itype in ["panel", "battery", "smartbattery", "controller",
			"appliance", "acload", "shelly4pm"]:
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
	var sm := get_node_or_null("/root/SimMode")
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

	var level: float = clampf(float(specs.get("level", 0.5)), 0.0, 1.0)
	var bar_w: float = inner.size.x
	var bar_h: float = maxf(inner.size.y * 0.55, 12.0)
	var bar_pos := Vector2(inner.position.x, inner.end.y - bar_h)

	# Tank outline
	var frame_col := kind_col if not is_ghost else Color(kind_col.r, kind_col.g, kind_col.b, 0.35)
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

	var pct_str := "%.0f%%" % (level * 100.0)
	draw_string(fnt, Vector2(bar_pos.x + bar_w * 0.5 - fsize, bar_pos.y + bar_h * 0.5 + fsize * 0.35),
		pct_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 1, Color(1, 1, 1, 0.92 if not is_ghost else 0.5))

	var cap_qty: float = float(specs.get("capacity_qty", 0.0))
	var cap_unit: String = str(specs.get("capacity_unit", ResourceKinds.default_unit(kind)))
	if cap_qty > 0.0:
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
		draw_string(fnt, Vector2(x, y), "biomass PBI",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)
	else:
		draw_string(fnt, Vector2(x, y), "runoff %.0f%%" % (float(specs.get("runoff_coeff", 0.85)) * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)


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
	var step  := 40.0 * _zoom
	var off   := Vector2(fposmod(_pan.x, step), fposmod(_pan.y, step))
	var dot_c := Color(0.133, 0.827, 0.933, 0.07 * canvas_bg_alpha)
	var x     := off.x
	while x < size.x:
		var y := off.y
		while y < size.y:
			draw_circle(Vector2(x, y), 1.0, dot_c)
			y += step
		x += step


# ---------------------------------------------------------------------------
# Coordinate helpers
# ---------------------------------------------------------------------------

func _item_screen_tl(item: Dictionary, center: Vector2) -> Vector2:
	return center + _pan + Vector2(float(item.get("x", 0.0)),
		float(item.get("y", 0.0))) * _zoom


func _item_screen_size(item: Dictionary) -> Vector2:
	return Vector2(float(item.get("width", 120.0)),
		float(item.get("height", 90.0))) * _zoom


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
		"breaker":      return "BREAKER"
		"combiner":     return "COMBINER"
		"solarcombiner":return "SOLAR COMBINER"
		"acbreaker":    return "AC BREAKER"
		"acoutlet":     return "AC OUTLET"
		"processor":    return "PROCESSOR"
		"resource":     return "RESOURCE"
		"catchment":    return "CATCHMENT"
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
	
	var col := Color.GRAY
	if kind == "solar" or kind == "sunlight" or kind == "thermal":
		col = Color(0.9, 0.8, 0.2)
	elif kind == "water" or kind == "rain":
		col = Color(0.2, 0.5, 0.9)
	elif kind == "wind" or kind == "mechanical":
		col = Color(0.6, 0.6, 0.6)
	elif kind == "biomass":
		col = Color(0.2, 0.7, 0.3)
		
	var center = rect.position + rect.size * 0.5
	var r = minf(rect.size.x, rect.size.y) * 0.5
	
	if is_active:
		var glow_r = r + (10.0 * _zoom) * (0.8 + 0.2 * sin(_flow_phase * TAU * 2.0))
		draw_circle(center, glow_r, Color(col.r, col.g, col.b, 0.3))
		
	draw_circle(center, r, col)
	draw_arc(center, r, 0, TAU, 32, Color(1,1,1,0.2), 2.0 * _zoom)
	
	var fnt = ThemeDB.fallback_font
	var fsize_title = _fit_font_size(rect, 1, 14.0)
	var title = str(specs.get("name", kind.capitalize()))
	
	var ts = fnt.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize_title)
	draw_string(fnt, center - Vector2(ts.x * 0.5, 2.0 * _zoom), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize_title, Color.WHITE)
	
	if not pbi_val.is_empty():
		var fsize_val = _fit_font_size(rect, 1, 11.0)
		var vs = fnt.get_string_size(pbi_val, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize_val)
		draw_string(fnt, center + Vector2(-vs.x * 0.5, fsize_val + 2.0 * _zoom), pbi_val, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize_val, Color(1,1,1,0.9))

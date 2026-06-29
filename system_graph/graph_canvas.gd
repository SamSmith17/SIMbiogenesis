extends Control
## GraphCanvas — pan/zoom drawing area for the solar circuit graph.
##
## Renders all graph items and connections stored in the GraphModel.
## Interactions: pan (MMB/RMB), zoom (wheel),
## item selection/drag (LMB), wire drag-to-connect (port dot LMB).

# ResourceKinds — global class_name from system_graph/data/resource_kinds.gd

# ---------------------------------------------------------------------------
# Color constants (webapp css/variables.css)
# ---------------------------------------------------------------------------
const C_CANVAS_BG  := Color(0.039, 0.055, 0.098, 1.0)   # align with SolarUI / timeline
const C_PANEL_BG   := Color(0.082, 0.114, 0.208, 0.96)  # deeper panel
const C_BORDER     := Color(0.227, 0.290, 0.420, 1.0)   # --space-400
const C_PRIMARY    := Color(0.133, 0.827, 0.933, 1.0)   # --clr-primary
const C_AMBER      := Color(0.941, 0.678, 0.306, 1.0)   # --energy-amber
const C_GREEN      := Color(0.063, 0.722, 0.506, 1.0)   # --energy-green
const C_RED        := Color(0.847, 0.329, 0.329, 1.0)   # #d9534f DC+
const C_TEXT       := Color(0.886, 0.910, 0.941, 1.0)   # --text-primary
const C_TEXT_S     := Color(0.580, 0.639, 0.722, 1.0)   # --text-secondary
const C_TEXT_M     := Color(0.392, 0.447, 0.545, 1.0)   # --text-muted
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
	"panel":         [196, 112],
	"battery":       [118, 158],
	"controller":    [168, 140],
	"appliance":     [184, 118],
	"acload":        [184, 118],
	"breaker":       [ 72,  92],
	"combiner":      [ 96, 118],
	"solarcombiner": [108, 118],
	"acbreaker":     [ 72,  82],
	"acoutlet":      [ 96,  82],
	"smartbattery":  [118, 158],
	"processor":     [154, 118],
	"resource":      [108, 104],
	"compound":      [208, 136],
	"shelly4pm":     [184, 148],
	"wind":          [148, 128],
	"hydro":         [148, 128],
	"catchment":     [128, 104],
}
const NODE_SIZE_DEFAULT := [142, 104]

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
		{"id": "positive", "polarity": "positive", "rx": 1.0, "ry": 0.5},
		{"id": "negative", "polarity": "negative", "rx": 0.0, "ry": 0.5},
	],
	"smartbattery": [
		{"id": "positive", "polarity": "smart_battery", "rx": 1.0, "ry": 0.5},
		{"id": "negative", "polarity": "negative",        "rx": 0.0, "ry": 0.5},
	],
	"controller": [
		{"id": "pvPositive",       "polarity": "positive", "rx": 0.25, "ry": 0.0},
		{"id": "pvNegative",       "polarity": "negative", "rx": 0.75, "ry": 0.0},
		{"id": "batteryPositive",  "polarity": "positive", "rx": 0.25, "ry": 1.0},
		{"id": "batteryNegative",  "polarity": "negative", "rx": 0.75, "ry": 1.0},
		{"id": "acOutput",         "polarity": "ac",       "rx": 1.0,  "ry": 0.5},
		{"id": "acOutputLeft",     "polarity": "ac",       "rx": 0.0,  "ry": 0.5},
		{"id": "acOutputTop",      "polarity": "ac",       "rx": 0.5,  "ry": 0.0},
		{"id": "acOutputBottom",   "polarity": "ac",       "rx": 0.5,  "ry": 1.0},
	],
	"appliance": [
		{"id": "input",       "polarity": "load", "rx": 0.0, "ry": 0.5},
		{"id": "inputRight",  "polarity": "load", "rx": 1.0, "ry": 0.5},
		{"id": "inputTop",    "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0},
	],
	"acload": [
		{"id": "input",       "polarity": "load", "rx": 0.0, "ry": 0.5},
		{"id": "inputRight",  "polarity": "load", "rx": 1.0, "ry": 0.5},
		{"id": "inputTop",    "polarity": "load", "rx": 0.5, "ry": 0.0},
		{"id": "inputBottom", "polarity": "load", "rx": 0.5, "ry": 1.0},
	],
	"breaker": [
		{"id": "input",  "polarity": "positive", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "positive", "rx": 0.5, "ry": 1.0},
	],
	"combiner": [
		{"id": "input1",  "polarity": "positive", "rx": 0.0, "ry": 0.25},
		{"id": "input2",  "polarity": "positive", "rx": 0.0, "ry": 0.5},
		{"id": "input3",  "polarity": "positive", "rx": 0.0, "ry": 0.75},
		{"id": "output",  "polarity": "positive", "rx": 1.0, "ry": 0.5},
	],
	"acbreaker": [
		{"id": "input",  "polarity": "ac", "rx": 0.5, "ry": 0.0},
		{"id": "output", "polarity": "ac", "rx": 0.5, "ry": 1.0},
	],
	"acoutlet": [
		{"id": "input",  "polarity": "ac",   "rx": 0.0, "ry": 0.5},
		{"id": "output", "polarity": "load", "rx": 1.0, "ry": 0.5},
	],
	"processor": [
		{"id": "power_in",  "polarity": "ac",       "rx": 0.5, "ry": 0.0},
		{"id": "output",    "polarity": "resource",  "rx": 1.0, "ry": 0.5},
	],
	"resource": [
		{"id": "input",  "polarity": "resource", "resource_kind": "water", "rx": 0.0, "ry": 0.5},
		{"id": "output", "polarity": "resource", "resource_kind": "water", "rx": 1.0, "ry": 0.5},
	],
	"catchment": [
		{"id": "output", "polarity": "resource", "resource_kind": "water", "rx": 1.0, "ry": 0.5},
	],
	"compound": [
		{"id": "in_ac_1",   "polarity": "ac",       "rx": 0.0, "ry": 0.35},
		{"id": "in_dc_1",   "polarity": "positive", "rx": 0.0, "ry": 0.65},
		{"id": "out_ac_1",  "polarity": "ac",       "rx": 1.0, "ry": 0.35},
		{"id": "out_dc_1",  "polarity": "positive", "rx": 1.0, "ry": 0.65},
	],
	# Shelly Pro 4PM: 1 AC feed in (left-center), 4 circuit outputs (right, evenly spaced)
	"shelly4pm": [
		{"id": "ac_in",     "polarity": "ac", "rx": 0.0, "ry": 0.50},
		{"id": "circuit_0", "polarity": "ac", "rx": 1.0, "ry": 0.21},
		{"id": "circuit_1", "polarity": "ac", "rx": 1.0, "ry": 0.40},
		{"id": "circuit_2", "polarity": "ac", "rx": 1.0, "ry": 0.60},
		{"id": "circuit_3", "polarity": "ac", "rx": 1.0, "ry": 0.79},
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
var _wire_src_handle_id: String     = ""
var _wire_src_polarity:  String     = ""
var _wire_src_pos:       Vector2    = Vector2.ZERO
var _wire_src_tangent:   Vector2    = Vector2.ZERO
var _wire_cursor_pos:    Vector2    = Vector2.ZERO
var _wire_snap:          Dictionary = {}    # nearest compatible/incompatible port
var _wire_snap_valid:    bool       = false
const SNAP_RADIUS_PX := 24.0

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
	_redraw_accum += delta
	if _redraw_accum >= REDRAW_INTERVAL:
		_redraw_accum = 0.0
		queue_redraw()


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
	# Block all emulated mouse traffic during touch — some panels emit RMB/MMB
	# on drag which would otherwise steal single-finger node moves as canvas pan.
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		return true
	return false


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
	if _wire_dragging:
		_wire_dragging = false
		_wire_snap = {}
		_wire_snap_valid = false
	if _item_dragging:
		_item_dragging = false
		_item_drag_id = ""
		_item_drag_ids.clear()
		_item_drag_start_map.clear()
	_marquee_selecting = false
	queue_redraw()


func _on_pointer_move(screen_pos: Vector2) -> void:
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


# Left-button press: port hit → wire drag; item hit → item drag.
func _on_lmb_press(screen_pos: Vector2) -> void:
	if model == null:
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
		if not _wire_snap.is_empty() and _wire_snap_valid:
			_finalize_connection()
		_wire_dragging   = false
		_wire_snap       = {}
		_wire_snap_valid = false
		queue_redraw()
		return

	if _item_dragging:
		var dist := screen_pos.distance_to(_item_drag_start_px)
		var moved := dist >= _effective_drag_threshold()
		if not moved:
			if selected_item_ids.size() <= 1 and not _item_drag_id.is_empty():
				if _touch_input_active():
					_try_emit_touch_double_tap(screen_pos, _item_drag_id)
				else:
					_select_item(_item_drag_id)
		else:
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


## Label font size that scales with zoom but clamps to fit inside the node body.
func _fit_font_size(inner: Rect2, lines: int = 1,
		base_graph_px: float = 11.0, max_graph_px: float = 13.0) -> int:
	var ideal := base_graph_px * _zoom
	ideal = minf(ideal, max_graph_px * _zoom)
	if lines > 0 and inner.size.y > 6.0:
		var per_line := (inner.size.y - 4.0) / float(lines)
		ideal = minf(ideal, per_line * 0.88)
	return clampi(int(round(ideal)), 7, 17)


func _fit_title_font_size(band_h: float) -> int:
	var ideal := minf(13.0, band_h * 0.42) * _zoom
	return clampi(int(round(ideal)), 9, 16)


func _wire_bezier_controls(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2, curve_tension: float = 1.0) -> Dictionary:
	var spread := _wire_spread(from, to) * curve_tension
	return {
		"c1": from + from_tang * spread,
		"c2": to + to_tang_in * spread,
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


## Energy-input port for processors (top edge — separate from resource I/O on the sides).
func _processor_energy_port(specs: Dictionary) -> Dictionary:
	var src: String = str(specs.get("energy_source", "ac"))
	if src.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		src = "ac"
	match src:
		"ac":
			return {"id": "power_in", "polarity": "ac", "rx": 0.5, "ry": 0.0}
		"thermal":
			return {"id": "energy_in", "polarity": "resource", "resource_kind": "thermal", "rx": 0.5, "ry": 0.0}
		"mechanical":
			return {"id": "energy_in", "polarity": "resource", "resource_kind": "biomass", "rx": 0.5, "ry": 0.0}
		_:
			return {}


## Dynamic port list from item specs (multi-I/O processors, typed resource tanks).
func _resolved_handles(item: Dictionary) -> Array:
	var custom: Array = item.get("handles", []) as Array
	if not custom.is_empty():
		return custom
	var itype: String = str(item.get("type", ""))
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if itype == "processor":
		ResourceKinds.new().migrate_processor_specs(specs)
		var handles: Array = []
		var energy_port := _processor_energy_port(specs)
		if not energy_port.is_empty():
			handles.append(energy_port)
		var inputs: Array = specs.get("inputs", []) as Array
		var outputs: Array = specs.get("outputs", []) as Array
		if inputs.is_empty() and outputs.is_empty():
			if handles.is_empty():
				return HANDLES.get("processor", []) as Array
			return handles
		for i: int in inputs.size():
			var inp: Dictionary = inputs[i] as Dictionary
			var n: int = maxi(inputs.size(), 1)
			var ry: float = float(i + 1) / float(n + 1)
			handles.append({
				"id": "res_in_%d" % i,
				"polarity": "resource",
				"resource_kind": str(inp.get("kind", "")),
				"rx": 0.0, "ry": ry,
			})
		for i: int in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			var n: int = maxi(outputs.size(), 1)
			var ry: float = float(i + 1) / float(n + 1)
			handles.append({
				"id": "res_out_%d" % i,
				"polarity": "resource",
				"resource_kind": str(outp.get("kind", "")),
				"rx": 1.0, "ry": ry,
			})
		return handles
	if itype == "resource":
		ResourceKinds.new().migrate_resource_specs(specs)
		var kind: String = str(specs.get("resource_kind", "water"))
		return [
			{"id": "input", "polarity": "resource", "resource_kind": kind, "rx": 0.0, "ry": 0.5},
			{"id": "output", "polarity": "resource", "resource_kind": kind, "rx": 1.0, "ry": 0.5},
		]
	if itype == "catchment":
		return HANDLES.get("catchment", []) as Array
	return HANDLES.get(itype, []) as Array


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
	queue_redraw()


func _finalize_connection() -> void:
	if model == null or _wire_snap.is_empty():
		return
	model.add_connection({
		"scope_id":         active_scope_id,
		"polarity":         _wire_src_polarity,
		"resource_type":    _wire_src_resource_kind if _wire_src_polarity == "resource" else "",
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


## Returns info for all handles on an item as an Array of Dictionaries.
func _get_all_handle_infos(item: Dictionary, center: Vector2) -> Array:
	var result: Array = []
	var tl    := _item_screen_tl(item, center)
	var sz    := _item_screen_size(item)
	var itype := item.get("type", "generic") as String
	var iw    := float(item.get("width",  120.0))
	var ih    := float(item.get("height",  90.0))

	var handles: Array = _resolved_handles(item)

	for h: Dictionary in handles:
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
			"handle_id": h.get("id",           "") as String,
			"polarity":  h.get("polarity", "positive") as String,
			"resource_kind": str(h.get("resource_kind", "")),
			"pos":       tl + Vector2(sz.x * rx, sz.y * ry),
			"tangent":   _tangent_from_rx_ry(rx, ry),
		})
	return result


## Handles that are visible and interactive — matches _draw_item_handles filtering.
func _get_interactive_handle_infos(item: Dictionary, center: Vector2) -> Array:
	var all := _get_all_handle_infos(item, center)
	var itype := item.get("type", "generic") as String
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
		if src_kind.is_empty() or tgt_kind.is_empty():
			return true
		return src_kind == tgt_kind
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
	if not _wire_snap.is_empty() and not _wire_snap_valid:
		col = C_RED

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


## Live PV output in watts (virtual array or any panel item).
func _solar_array_output_w() -> float:
	if model == null:
		return 0.0
	for it: Dictionary in _visible_items():
		var iid: String = it.get("id", "") as String
		if iid == "virtual_solar_array" or it.get("type", "") == "panel":
			var sp: Dictionary = it.get("specs", {}) as Dictionary
			return maxf(0.0, float(sp.get("current_output_kw", 0.0)) * 1000.0)
	return 0.0


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
		if _is_load_group_item(load_item):
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

	# Controller ↔ battery (graph stores controller as source, battery as target)
	if (sid == "virtual_controller" and tid == "virtual_battery") or \
			(sid == "virtual_battery" and tid == "virtual_controller"):
		var w_b: float  = minf(12000.0, maxf(WIRE_FLOW_FLOOR, absf(net) * 0.95))
		var rev:  bool  = (net < 0.0) # discharge: power runs battery → controller
		# Battery ↔ controller always active as long as something is happening
		var active_b: bool = (w_b > WIRE_DEAD_W * 2.0)
		return {"watts": w_b, "reverse": rev, "active": active_b}

	# Resource flow wires — animate from ResourceFlowEngine throughput
	if pol == "resource":
		var flow_rate: float = 0.0
		var active_r: bool = false
		if resource_flow_engine != null and resource_flow_engine.has_method("get_connection_flow"):
			var rf: Dictionary = resource_flow_engine.call(
				"get_connection_flow", str(conn.get("id", ""))) as Dictionary
			flow_rate = float(rf.get("rate", 0.0))
			active_r = bool(rf.get("active", false))
		if not active_r:
			# Fallback: driving processor output rate label
			var proc: Dictionary = sitem if st == "processor" else titem if tt == "processor" else {}
			if not proc.is_empty():
				var psp: Dictionary = (proc.get("specs", {}) as Dictionary).duplicate(true)
				ResourceKinds.new().migrate_processor_specs(psp)
				var outs: Array = psp.get("outputs", []) as Array
				if outs.size() > 0:
					flow_rate = float((outs[0] as Dictionary).get("rate", 0.0))
					active_r = flow_rate > 0.001 and _processor_is_active(proc)
		return {"watts": maxf(flow_rate, WIRE_FLOW_FLOOR), "reverse": false, "active": active_r}

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
	var src := _get_handle_info(
		conn.get("source_item_id", "") as String,
		conn.get("source_handle_id", "") as String, center)
	var tgt := _get_handle_info(
		conn.get("target_item_id", "") as String,
		conn.get("target_handle_id", "") as String, center)
	if src.is_empty() or tgt.is_empty():
		return

	var polarity    := conn.get("polarity", "positive") as String
	var is_sel:  bool = (conn.get("id", "") as String == selected_connection_id)
	var base_col  := _wire_color_for_connection(conn, polarity)
	var col: Color = C_SELECTED_BORDER if is_sel else base_col
	var flow_est      := _estimate_connection_flow(conn, solar_w, load_w)
	var flow_watts:   float  = float(flow_est.get("watts", 100.0))
	var reverse: bool = bool(flow_est.get("reverse", false))
	var flow_active:  bool   = bool(flow_est.get("active", true))
	var wire_shed: bool = bool(flow_est.get("shed", false))
	if wire_shed:
		flow_active = false
		var flash: float = 0.62 + 0.38 * abs(sin(_flow_phase * 7.5))
		col = Color(col.r * 0.40 * flash, col.g * 0.40 * flash, col.b * 0.40 * flash, 0.45 + 0.25 * flash)

	# Power-scaled wire width: thicker at high load so flow is obvious at a glance
	var gscale_w  := _wire_glow_scale_from_watts(flow_watts)
	var width: float = (6.5 if is_sel else WIRE_BASE_W + gscale_w * 2.4)

	# In Test mode wires animate if power is actually flowing; Build mode is always static
	var flowing: bool = (current_mode == "test") and flow_active

	var tgt_tang_in := _incoming_tangent(tgt.get("tangent", Vector2.RIGHT) as Vector2)
	var wps: Array = _waypoints_screen(conn, center)
	var style: String = str(conn.get("line_style", "bezier"))
	var curve_t := _conn_curve_tension(conn)
	var src_pos: Vector2 = src.get("pos", Vector2.ZERO) as Vector2
	var tgt_pos: Vector2 = tgt.get("pos", Vector2.ZERO) as Vector2
	var src_t: Vector2 = src.get("tangent", Vector2.RIGHT) as Vector2
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
	_draw_connection_waypoint_handles(conn, center)


func _bezier_pos(from: Vector2, c1: Vector2, c2: Vector2, to: Vector2, t: float) -> Vector2:
	return from.bezier_interpolate(c1, c2, to, t)


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
			var wch_outer := maxf(3.5, (width * (1.2 + 1.8 * gscale) + 1.0) * _zoom)
			draw_line(p0, p1, Color(col.r, col.g, col.b, (0.18 + 0.24 * gscale) * tail_fade), wch_outer)
			# Bright core
			var a_ch := (0.60 + 0.40 * gscale) * tail_fade
			var wch  := maxf(2.0, (width * (0.9 + 1.5 * gscale) + 0.5) * _zoom)
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
		var wch_outer := maxf(3.5, (width * (1.2 + 1.8 * gscale) + 1.0) * _zoom)
		draw_line(p0, p1, Color(col.r, col.g, col.b, (0.18 + 0.24 * gscale) * tail_fade), wch_outer)
		var a_ch := (0.60 + 0.40 * gscale) * tail_fade
		var wch := maxf(2.0, (width * (0.9 + 1.5 * gscale) + 0.5) * _zoom)
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
	var src := _get_handle_info(
		conn.get("source_item_id", "") as String,
		conn.get("source_handle_id", "") as String, center)
	var tgt := _get_handle_info(
		conn.get("target_item_id", "") as String,
		conn.get("target_handle_id", "") as String, center)
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
	var src := _get_handle_info(
		conn.get("source_item_id", "") as String,
		conn.get("source_handle_id", "") as String, center)
	var tgt := _get_handle_info(
		conn.get("target_item_id", "") as String,
		conn.get("target_handle_id", "") as String, center)
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
	var bits := handle_id.split("_")
	if bits.size() < 3:
		return {}
	var idx: int = int(bits[bits.size() - 1])
	if idx <= 0:
		idx = 1
	var in_count: int = maxi(0, int(specs.get("port_in_count", 0)))
	var out_count: int = maxi(0, int(specs.get("port_out_count", 0)))
	var total: int = maxi(1, in_count + out_count)
	# Place all array boundary ports along the bottom edge so condensed arrays
	# preserve the same downward visual flow as expanded panel strings.
	var t := float(idx) / float(total + 1)
	return {"rx": t, "ry": 1.0}


## Returns {pos: Vector2, tangent: Vector2} for a named handle on an item,
## or {} if the item or handle cannot be found.
func _get_handle_info(item_id: String, handle_id: String,
		center: Vector2) -> Dictionary:
	if model == null or item_id.is_empty() or handle_id.is_empty():
		return {}
	var item := model.get_item(item_id)
	if item.is_empty():
		return {}

	var tl    := _item_screen_tl(item, center)
	var sz    := _item_screen_size(item)
	var itype := item.get("type", "generic") as String

	var rx := 0.5
	var ry := 0.5
	var found := false

	# 1. Check item's own handles array (may have absolute x/y or rx/ry)
	for h: Dictionary in (item.get("handles", []) as Array):
		if h.get("id", "") == handle_id:
			if h.has("rx"):
				rx = float(h["rx"])
				ry = float(h["ry"])
			else:
				# Absolute pixel offsets stored during Phase 6 wiring
				var iw := float(item.get("width",  120.0))
				var ih := float(item.get("height",  90.0))
				rx = float(h.get("x", 0.0)) / maxf(1.0, iw)
				ry = float(h.get("y", 0.0)) / maxf(1.0, ih)
			found = true
			break

	# 2. Fall back to built-in / dynamic handles for the type
	if not found:
		for h: Dictionary in _resolved_handles(item):
			if h.get("id", "") == handle_id:
				rx = float(h.get("rx", 0.5))
				ry = float(h.get("ry", 0.5))
				found = true
				break

	if not found:
		return {}
	var arr_override := _array_compound_handle_override(item, handle_id)
	if not arr_override.is_empty():
		rx = float(arr_override.get("rx", rx))
		ry = float(arr_override.get("ry", ry))

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
		var src := _get_handle_info(
			conn.get("source_item_id", "") as String,
			conn.get("source_handle_id", "") as String, center)
		var tgt := _get_handle_info(
			conn.get("target_item_id", "") as String,
			conn.get("target_handle_id", "") as String, center)
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
	draw_rect(Rect2(Vector2.ZERO, size), Color(C_CANVAS_BG.r, C_CANVAS_BG.g, C_CANVAS_BG.b, C_CANVAS_BG.a * canvas_bg_alpha))
	_draw_dot_grid()

	if model != null and _visible_items().size() > 0:
		_draw_connections()
		for item: Dictionary in _visible_items():
			_render_item(item)

	_draw_temp_wire()                # always on top of everything
	if _marquee_selecting:
		var rect := Rect2(_marquee_start, _marquee_end - _marquee_start).abs()
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.14), true)
		draw_rect(rect, Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.65), false, 1.6)


# ---------------------------------------------------------------------------
# Model-driven item rendering
# ---------------------------------------------------------------------------

func _render_item(item: Dictionary) -> void:
	var itype   := item.get("type", "generic") as String
	var center  := size * 0.5
	var tl      := _item_screen_tl(item, center)
	var sz      := _item_screen_size(item)
	var rect    := Rect2(tl, sz)
	var iid: String = item.get("id", "") as String
	var is_sel: bool = (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs   := item.get("specs", {}) as Dictionary

	# Active load highlight (behind frame)
	if itype in ["appliance", "acload", "processor"]:
		var st := str(specs.get("current_state", "")).to_lower()
		var avg := float(specs.get("avg_watts", 0.0))
		if st == "on" or (st.is_empty() and avg > 0.5):
			var glow := rect.grow(maxf(2.5, 3.0 * _zoom))
			draw_rect(glow, C_ACTIVE_LOAD_GLOW, true)

	# Node background + border
	var border_col := NODE_BORDER_COLORS.get(itype, C_BORDER) as Color
	if bool(item.get("is_ghost", false)):
		border_col = Color(border_col.r, border_col.g, border_col.b, 0.45)
	if is_sel:
		border_col = C_SELECTED_BORDER
	_draw_node_frame(rect, border_col)

	# Title band
	var title_h := maxf(26.0, sz.y * 0.28)
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
			_draw_controller_body(body_rect, specs)
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
	_draw_item_handles(item, tl, sz)

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
	var band_h: float = maxf(26.0, rect.size.y * 0.28)
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
	draw_string(fnt,
		Vector2(rect.position.x + 10.0, cy),
		title, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.92, 0.95, 0.99, 1.0))


func _draw_wind_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt: Font = ThemeDB.fallback_font
	var inner: Rect2 = rect.grow(-4.0)
	var fsize: int = _fit_font_size(inner, 4, 9.0, 11.0)
	if inner.size.x < 4.0 or inner.size.y < 4.0:
		return
	var out_kw := float(specs.get("current_output_kw", 0.0))
	var producing := out_kw > 0.0001

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
	draw_string(fnt, Vector2(tx, y), "Capacity %.2f kWh" % kwh, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_GREEN)
	y  += fsize + 2.0
	if y < inner.end.y - 1.0:
		draw_string(fnt, Vector2(tx, y), "SoC %.0f%%" % (soc * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 1, C_TEXT_M)


func _draw_controller_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 1, 11.0)
	var x     := rect.position.x + 10.0
	var y     := rect.position.y + fsize + 6.0
	var name_ := specs.get("name", "MPPT Controller") as String
	draw_string(fnt, Vector2(x, y), name_,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)


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
	var fsize := _fit_font_size(rect, 1, 10.0)
	var x     := rect.position.x + 8.0
	var y     := rect.position.y + fsize + 6.0
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
	var fsize := _fit_font_size(rect, 3, 10.0, 12.0)
	var x     := rect.position.x + 10.0
	var y     := rect.position.y + fsize + 5.0
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


func _draw_catchment_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt   := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 1, 10.0)
	var x     := rect.position.x + 8.0
	var y     := rect.position.y + fsize + 4.0
	draw_string(fnt, Vector2(x, y), specs.get("name", "Rain Catchment") as String,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	y += fsize + 4.0
	draw_string(fnt, Vector2(x, y), "%.0f m²" % float(specs.get("area_m2", 10.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT)
	y += fsize + 3.0
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
	var handles := _resolved_handles(item)

	# For types that have "extra" symmetry handles, only render a dot for:
	#   a) primary/canonical handles, OR
	#   b) handles that are currently wired to something.
	# This prevents four dots cluttering every load/inverter node.
	var primary: Array = _PRIMARY_HANDLES.get(itype, []) as Array
	var filter_extras: bool = not primary.is_empty()
	var wired: Dictionary  = _wired_handle_ids(item.get("id", "") as String) if filter_extras else {}

	for h: Dictionary in handles:
		var hid := h.get("id", "") as String
		if filter_extras and not primary.has(hid) and not wired.has(hid):
			continue
		var rx  := float(h.get("rx", h.get("x", 0.0) / maxf(1.0, float(item.get("width",  120.0)))))
		var ry  := float(h.get("ry", h.get("y", 0.0) / maxf(1.0, float(item.get("height",  90.0)))))
		var arr_override := _array_compound_handle_override(item, hid)
		if not arr_override.is_empty():
			rx = float(arr_override.get("rx", rx))
			ry = float(arr_override.get("ry", ry))
		var pol := h.get("polarity", "positive") as String
		var rk := str(h.get("resource_kind", ""))
		var sp  := tl + Vector2(sz.x * rx, sz.y * ry)
		_draw_port_dot(sp, pol, rk)


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

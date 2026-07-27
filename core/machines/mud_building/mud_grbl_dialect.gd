class_name MudGrblDialect
extends RefCounted

## Machine-specific GRBL prelude/epilogue + axis quirks for mud building export.
## Path generator stays dialect-agnostic; pump control lives here.

## How the pump/auger is driven:
## - RELAY: classic GRBL (no E axis). Pump switches on/off via an M-code; flow is
##   governed purely by feedrate. Default for the real large-format mud printer.
## - SPINDLE_PWM: auger speed mapped to the spindle output (M3 S<flow> / M5).
## - E_AXIS: controller genuinely has an extruder axis (grblHAL/Marlin-like) —
##   emit cumulative volumetric E words.
enum ExtrusionMode { RELAY, SPINDLE_PWM, E_AXIS }

## Inserted before the mandatory G21/G90 block (comments + optional M-codes).
var prelude: String = "; SIMbiogenesis mud building\n; pump = relay on/off, flow by feedrate\n"
## Appended after the path (use {safe_z} for park height in mm). The exporter
## turns the pump OFF before this block, so the epilogue only needs to park.
var epilogue: String = "G0 Z{safe_z}\nM2\n"
var max_feed_mm_min: float = 7200.0
var travel_feed_mm_min: float = 3000.0
var print_feed_mm_min: float = 0.0  # 0 → derive from print_speed_mm_s
var xy_swap: bool = false
var origin_offset_mm: Vector2 = Vector2.ZERO
## Multiplier on volumetric E (E_AXIS mode only; tune to the pump's expected scale).
var e_scale: float = 1.0
## Extra Z above the print top when parking (mm).
var safe_z_lift_mm: float = 50.0

var extrusion_mode: int = ExtrusionMode.RELAY
## Pump-on / pump-off M-codes (RELAY + SPINDLE_PWM). Some rigs wire the pump to
## the coolant output instead — set these to "M8"/"M9".
var relay_on_code: String = "M3"
var relay_off_code: String = "M5"
## Spindle flow value for SPINDLE_PWM mode (M3 S<flow>).
var spindle_flow_s: float = 1000.0
## Shift the (centered) plan so its min corner lands at origin_offset_mm — i.e. a
## positive work envelope for a corner-homing machine. Off = keep bed-center 0,0.
var corner_origin: bool = true
## Z lift for travel (pen-up) moves so the nozzle clears printed walls (mm).
var travel_hop_mm: float = 15.0
## Dwell to prime the pump before the first extrusion (s).
var prime_dwell_s: float = 1.0
## Dwell at the start of each new layer to let mud settle (s). 0 = none.
var layer_dwell_s: float = 0.0
## Lay a short purge/prime line before the print to establish flow.
var purge_enabled: bool = true
var purge_len_mm: float = 200.0
var purge_margin_mm: float = 60.0


static func default_dialect() -> MudGrblDialect:
	return MudGrblDialect.new()


func has_e_axis() -> bool:
	return extrusion_mode == ExtrusionMode.E_AXIS


func duplicate_dialect() -> MudGrblDialect:
	var d := MudGrblDialect.new()
	d.prelude = prelude
	d.epilogue = epilogue
	d.max_feed_mm_min = max_feed_mm_min
	d.travel_feed_mm_min = travel_feed_mm_min
	d.print_feed_mm_min = print_feed_mm_min
	d.xy_swap = xy_swap
	d.origin_offset_mm = origin_offset_mm
	d.e_scale = e_scale
	d.safe_z_lift_mm = safe_z_lift_mm
	d.extrusion_mode = extrusion_mode
	d.relay_on_code = relay_on_code
	d.relay_off_code = relay_off_code
	d.spindle_flow_s = spindle_flow_s
	d.corner_origin = corner_origin
	d.travel_hop_mm = travel_hop_mm
	d.prime_dwell_s = prime_dwell_s
	d.layer_dwell_s = layer_dwell_s
	d.purge_enabled = purge_enabled
	d.purge_len_mm = purge_len_mm
	d.purge_margin_mm = purge_margin_mm
	return d


func to_dict() -> Dictionary:
	return {
		"prelude": prelude,
		"epilogue": epilogue,
		"max_feed_mm_min": max_feed_mm_min,
		"travel_feed_mm_min": travel_feed_mm_min,
		"print_feed_mm_min": print_feed_mm_min,
		"xy_swap": xy_swap,
		"origin_offset_x": origin_offset_mm.x,
		"origin_offset_y": origin_offset_mm.y,
		"e_scale": e_scale,
		"safe_z_lift_mm": safe_z_lift_mm,
		"extrusion_mode": extrusion_mode,
		"relay_on_code": relay_on_code,
		"relay_off_code": relay_off_code,
		"spindle_flow_s": spindle_flow_s,
		"corner_origin": corner_origin,
		"travel_hop_mm": travel_hop_mm,
		"prime_dwell_s": prime_dwell_s,
		"layer_dwell_s": layer_dwell_s,
		"purge_enabled": purge_enabled,
		"purge_len_mm": purge_len_mm,
		"purge_margin_mm": purge_margin_mm,
	}


static func from_dict(d: Dictionary) -> MudGrblDialect:
	var x := MudGrblDialect.new()
	x.prelude = str(d.get("prelude", x.prelude))
	x.epilogue = str(d.get("epilogue", x.epilogue))
	x.max_feed_mm_min = float(d.get("max_feed_mm_min", x.max_feed_mm_min))
	x.travel_feed_mm_min = float(d.get("travel_feed_mm_min", x.travel_feed_mm_min))
	x.print_feed_mm_min = float(d.get("print_feed_mm_min", x.print_feed_mm_min))
	x.xy_swap = bool(d.get("xy_swap", x.xy_swap))
	x.origin_offset_mm = Vector2(
		float(d.get("origin_offset_x", 0.0)),
		float(d.get("origin_offset_y", 0.0)))
	x.e_scale = float(d.get("e_scale", x.e_scale))
	x.safe_z_lift_mm = float(d.get("safe_z_lift_mm", x.safe_z_lift_mm))
	x.extrusion_mode = int(d.get("extrusion_mode", x.extrusion_mode))
	x.relay_on_code = str(d.get("relay_on_code", x.relay_on_code))
	x.relay_off_code = str(d.get("relay_off_code", x.relay_off_code))
	x.spindle_flow_s = float(d.get("spindle_flow_s", x.spindle_flow_s))
	x.corner_origin = bool(d.get("corner_origin", x.corner_origin))
	x.travel_hop_mm = float(d.get("travel_hop_mm", x.travel_hop_mm))
	x.prime_dwell_s = float(d.get("prime_dwell_s", x.prime_dwell_s))
	x.layer_dwell_s = float(d.get("layer_dwell_s", x.layer_dwell_s))
	x.purge_enabled = bool(d.get("purge_enabled", x.purge_enabled))
	x.purge_len_mm = float(d.get("purge_len_mm", x.purge_len_mm))
	x.purge_margin_mm = float(d.get("purge_margin_mm", x.purge_margin_mm))
	return x

class_name ConduitKinds
extends RefCounted

## Registry of physical 3D conduit styles (extension cord, hose, pipe, etc.).
## Maps graph connection polarity / resource_type to a renderable conduit profile.
## User extensions load from user://conduit_kinds.cfg (never committed).

const CONFIG_PATH := "user://conduit_kinds.cfg"

## Loss-model fields (Wave 8):
##  Electrical kinds:
##    resistance_ohm_per_m — ROUND-TRIP loop resistance per metre of run
##      (both conductors). Copper resistivity per AWG from NEC Ch.9 Table 8.
##    ampacity_a           — continuous current rating (NEC 400.5 flexible cords
##                           / NEC 310.16 building wire).
##    nominal_volts        — operating voltage used to derive current from power.
##  Fluid kinds:
##    inner_diameter_m     — hydraulic inner diameter.
##    hw_c                 — Hazen-Williams roughness coefficient C
##                           (Mays, Water Distribution Systems Handbook, ~150 smooth plastic).
##    max_flow_lpm         — practical flow rating.
##    burst_pressure_psi   — burst rating (overload/burst threshold).
##  Light kinds additionally set:
##    is_light: true, bulb_spacing_m (0 = continuous emissive strip),
##    watts_per_m, light_color.
const BUILTIN: Dictionary = {
	"conceptual_flow": {
		"label": "Conceptual Flow",
		"radius_m": 0.022,
		"color": Color(0.40, 0.82, 0.95, 1.0),
		"roughness": 0.35,
		"metallic": 0.0,
		# Pipes-screensaver axis sections + elbows (see ConduitPipesRouter).
		"flexible": false,
		"sag_amount": 0.0,
		"ground_drape": false,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.5,
		"fitting_step_deg": 45.0,
		"conceptual": true,
		"dashed": true,
		"emissive": true,
		"emission_energy": 0.55,
		"use_flow_shader": true,
		"flow_strength_default": 0.0,
	},
	"extension_cord": {
		"label": "Extension Cord",
		"radius_m": 0.016,
		"color": Color(0.95, 0.82, 0.08, 1.0),  # safety yellow jacket
		"roughness": 0.85,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.35,
		"end_slack_m": 0.30,
		"ground_drape": true,
		"fitting_color": Color(0.85, 0.12, 0.1, 1.0),  # red plugs
		"plug_emissive": true,
		"jacket_emissive": false,
		"max_segment_m": 15.0,  # common 50 ft outdoor cord stock
		# 16 AWG copper: 13.2 mOhm/m/conductor -> 26.4 mOhm/m loop (NEC Ch.9 T8).
		"resistance_ohm_per_m": 0.0264,
		"ampacity_a": 13.0,  # NEC 400.5 16 AWG cord
		"nominal_volts": 120.0,
	},
	"romex": {
		"label": "Romex / NM-B",
		"radius_m": 0.008,
		"color": Color(0.95, 0.93, 0.86, 1.0),
		"roughness": 0.9,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "ortho",  # in-wall runs follow studs / joists at right angles
		# 12 AWG copper: 5.21 mOhm/m/conductor -> 10.4 mOhm/m loop.
		"resistance_ohm_per_m": 0.0104,
		"ampacity_a": 20.0,  # NEC 310.16 12 AWG @60C
		"nominal_volts": 120.0,
	},
	"dc_solar": {
		"label": "DC Solar Wire",
		"radius_m": 0.005,
		"color": Color(0.08, 0.08, 0.1, 1.0),
		"roughness": 0.8,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.1,
		# 10 AWG PV wire: 3.28 mOhm/m/conductor -> 6.6 mOhm/m loop.
		"resistance_ohm_per_m": 0.0066,
		"ampacity_a": 30.0,  # NEC 310.16 10 AWG
		"nominal_volts": 48.0,
	},
	"garden_hose": {
		"label": "Garden Hose",
		"radius_m": 0.015,
		"color": Color(0.12, 0.62, 0.20, 1.0),
		"roughness": 0.72,
		"metallic": 0.0,
		"clearcoat": 0.12,  # soft rubber sheen (not wet plastic)
		# Match extension-cord drape feel — high slack/sag made short spans zigzag.
		"end_slack_m": 0.32,
		"flexible": true,
		"sag_amount": 0.36,
		"ground_drape": true,
		"fitting_color": Color(0.55, 0.55, 0.58, 1.0),
		"inner_diameter_m": 0.016,  # 5/8 in ID
		"hw_c": 140.0,
		"max_flow_lpm": 40.0,
		"burst_pressure_psi": 350.0,
	},
	"pvc_pipe": {
		"label": "PVC Pipe (Sch40)",
		"radius_m": 0.021,  # ~1¼″ OD/2 fallback; kit OD wins at runtime
		"color": Color(0.90, 0.90, 0.91, 1.0),  # dull white PVC
		"roughness": 0.62,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.0,  # sharp — real Sch40 elbow meshes
		"fitting_step_deg": 45.0,
		"fitting_color": Color(0.86, 0.86, 0.88, 1.0),
		"fitting_collars": false,
		"clearcoat": 0.06,
		"pipe_kit_family": "us_sch40",
		"default_pipe_size_in": 1.25,
		"inner_diameter_m": 0.0351,  # 1¼″ Sch40 ID approx
		"hw_c": 150.0,
		"max_flow_lpm": 100.0,
		"burst_pressure_psi": 450.0,
	},
	"pvc_4in": {
		"label": "PVC Pipe (4\" Sch40)",
		"radius_m": 0.05715,
		"color": Color(0.90, 0.90, 0.91, 1.0),
		"roughness": 0.62,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.0,
		"fitting_step_deg": 45.0,
		"fitting_color": Color(0.86, 0.86, 0.88, 1.0),
		"fitting_collars": false,
		"clearcoat": 0.06,
		"pipe_kit_family": "us_sch40",
		"default_pipe_size_in": 4.0,
		"inner_diameter_m": 0.10226,
		"hw_c": 150.0,
		"max_flow_lpm": 1400.0,
		"burst_pressure_psi": 220.0,
	},
	"pvc_6in": {
		"label": "PVC Pipe (6\" Sch40)",
		"radius_m": 0.08414,
		"color": Color(0.90, 0.90, 0.91, 1.0),
		"roughness": 0.62,
		"metallic": 0.0,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.0,
		"fitting_step_deg": 45.0,
		"fitting_color": Color(0.86, 0.86, 0.88, 1.0),
		"fitting_collars": false,
		"clearcoat": 0.06,
		"pipe_kit_family": "us_sch40",
		"default_pipe_size_in": 6.0,
		"inner_diameter_m": 0.15405,
		"hw_c": 150.0,
		"max_flow_lpm": 3200.0,
		"burst_pressure_psi": 180.0,
	},
	"abs_dwv": {
		"label": "ABS DWV (Black)",
		"radius_m": 0.036,  # ~2½″ OD/2 fallback; kit OD wins at runtime
		"color": Color(0.05, 0.05, 0.055, 1.0),  # dull ABS black
		"roughness": 0.68,
		"metallic": 0.0,
		"clearcoat": 0.05,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.0,
		"fitting_step_deg": 45.0,
		"fitting_color": Color(0.04, 0.04, 0.045, 1.0),
		"fitting_collars": false,
		"pipe_kit_family": "us_sch40",
		"default_pipe_size_in": 2.5,
		"inner_diameter_m": 0.062,
		"hw_c": 130.0,
		"max_flow_lpm": 800.0,
		"burst_pressure_psi": 60.0,
	},
	"pex_red": {
		"label": "PEX (Red / Hot)",
		"radius_m": 0.008,
		"color": Color(0.78, 0.16, 0.14, 1.0),
		"roughness": 0.4,
		"metallic": 0.0,
		"clearcoat": 0.45,  # glossy PEX tubing
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,  # 1/2 in PEX ID
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"pex_blue": {
		"label": "PEX (Blue / Cold)",
		"radius_m": 0.008,
		"color": Color(0.16, 0.34, 0.78, 1.0),
		"roughness": 0.4,
		"metallic": 0.0,
		"clearcoat": 0.45,  # glossy PEX tubing
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"pex_white": {
		"label": "PEX (White)",
		"radius_m": 0.008,
		"color": Color(0.9, 0.9, 0.88, 1.0),
		"roughness": 0.4,
		"metallic": 0.0,
		"clearcoat": 0.45,  # glossy PEX tubing
		"flexible": true,
		"sag_amount": 0.08,
		"inner_diameter_m": 0.0121,
		"hw_c": 150.0,
		"max_flow_lpm": 30.0,
		"burst_pressure_psi": 480.0,
	},
	"ethernet": {
		"label": "Ethernet (Cat6)",
		"radius_m": 0.0035,  # ~7 mm Cat6 jacket
		"color": Color(0.12, 0.34, 0.78, 1.0),  # classic patch-cable blue
		"roughness": 0.55,
		"metallic": 0.0,
		"clearcoat": 0.4,  # smooth PVC jacket sheen
		"flexible": true,
		"sag_amount": 0.06,  # structured cabling runs tidy, minimal droop
		"route_mode": "ortho",  # data cabling follows walls / trays orthogonally
		"fitting_color": Color(0.5, 0.55, 0.62, 1.0),  # RJ45 boot
		# 24 AWG copper: 84.2 mOhm/m/conductor -> 168 mOhm/m loop (PoE pair).
		"resistance_ohm_per_m": 0.168,
		"ampacity_a": 0.6,  # IEEE 802.3bt per-pair limit
		"nominal_volts": 48.0,
	},
	"ducting": {
		"label": "Ducting",
		"radius_m": 0.085,
		"color": Color(0.72, 0.76, 0.80, 1.0),
		"roughness": 0.48,
		"metallic": 0.15,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "pipes",
		"elbow_radius_frac": 0.5,
		"fitting_step_deg": 45.0,
		"fitting_color": Color(0.55, 0.58, 0.62, 1.0),
		"fitting_collars": true,
		"inner_diameter_m": 0.15,
		"hw_c": 120.0,
		"max_flow_lpm": 5000.0,
		"burst_pressure_psi": 10.0,
	},
	"culvert_pipe": {
		"label": "Culvert Pipe",
		"radius_m": 0.12,  # ~8″ OD/2 fallback; kit OD wins at runtime
		"color": Color(0.42, 0.42, 0.40, 1.0),  # black/grey corrugated PE
		"roughness": 0.78,
		"metallic": 0.0,
		"clearcoat": 0.04,
		"flexible": false,
		"sag_amount": 0.0,
		"route_mode": "culvert",
		"elbow_radius_frac": 0.0,
		"fitting_step_deg": 0.0,
		"bend_radius_od_mult": 4.0,  # dual-wall PE ~3–5× OD sweeps
		"fitting_collars": false,
		"pipe_kit_family": "pe_culvert",
		"default_pipe_size_in": 8.0,
		"inner_diameter_m": 0.203,  # 8″ ID approx
		"manning_n": 0.012,  # dual-wall PE free-surface
		"hw_c": 155.0,  # smooth-interior dual-wall PE (pressurized fallback)
		"max_flow_lpm": 2500.0,
		"burst_pressure_psi": 30.0,
	},
	"led_strip": {
		"label": "LED Strip",
		"radius_m": 0.004,
		"color": Color(0.85, 0.85, 0.8, 1.0),
		"roughness": 0.5,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.05,
		"is_light": true,
		"route_mode": "taut",  # adhesive strip mounts in straight runs
		"bulb_spacing_m": 0.0,  # continuous emissive strip, no discrete bulbs
		"watts_per_m": 14.0,    # 5050 SMD strip @ 12 V
		"light_color": Color(1.0, 0.92, 0.8, 1.0),
		# 12 V strip copper traces: ~0.15 Ohm/m loop (typical 10 mm 2 oz PCB).
		"resistance_ohm_per_m": 0.15,
		"ampacity_a": 5.0,
		"nominal_volts": 12.0,
	},
	"led_fairy": {
		"label": "Fairy Lights",
		"radius_m": 0.0015,
		"color": Color(0.35, 0.3, 0.2, 1.0),
		"roughness": 0.9,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.3,
		"ground_drape": true,
		"is_light": true,
		"bulb_spacing_m": 0.15,
		"watts_per_m": 0.6,  # 5 V USB micro-LED string
		"light_color": Color(1.0, 0.88, 0.65, 1.0),
		# 30 AWG copper: 0.34 Ohm/m/conductor -> 0.68 Ohm/m loop.
		"resistance_ohm_per_m": 0.68,
		"ampacity_a": 0.8,
		"nominal_volts": 5.0,
	},
	"led_patio": {
		"label": "Patio String Lights",
		"radius_m": 0.004,
		"color": Color(0.08, 0.08, 0.08, 1.0),
		"roughness": 0.85,
		"metallic": 0.0,
		"flexible": true,
		"sag_amount": 0.35,
		"is_light": true,
		"route_mode": "catenary",  # strung overhead between posts, hangs in a sag
		"bulb_spacing_m": 0.9,
		"watts_per_m": 3.3,  # ~3 W LED filament bulb every 0.9 m
		"light_color": Color(1.0, 0.82, 0.55, 1.0),
		# 18 AWG SPT-1 lamp cord: 21 mOhm/m/conductor -> 42 mOhm/m loop.
		"resistance_ohm_per_m": 0.042,
		"ampacity_a": 10.0,
		"nominal_volts": 120.0,
	},
}

## Default mapping from ResourceKinds id → conduit type id.
const RESOURCE_DEFAULTS: Dictionary = {
	"electric": "extension_cord",
	"water": "garden_hose",
	"hot_water": "pex_red",
	"woodgas": "pvc_pipe",
	"thermal": "ducting",
	"biomass": "pvc_pipe",
	"food_waste": "pvc_pipe",
	"manure": "pvc_pipe",
	"biogas": "pvc_pipe",
	"liquid_fertilizer": "garden_hose",
	"plastic_waste": "pvc_pipe",
	"plastic_shred": "pvc_pipe",
	"plastic_flake": "pvc_pipe",
	"plastic_sheet": "pvc_pipe",
	"biochar": "pvc_pipe",
	"food": "garden_hose",
	"propane": "pvc_pipe",
	"money": "pvc_pipe",
	"chore_hours": "pvc_pipe",
	"stormwater": "culvert_pipe",
	"runoff": "culvert_pipe",
}

static var _extra: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_extra.clear()
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for section in cfg.get_sections():
		if section == "meta":
			continue
		var label: String = str(cfg.get_value(section, "label", section.capitalize()))
		var radius: float = float(cfg.get_value(section, "radius_m", 0.01))
		var cr: float = float(cfg.get_value(section, "color_r", 0.58))
		var cg: float = float(cfg.get_value(section, "color_g", 0.64))
		var cb: float = float(cfg.get_value(section, "color_b", 0.72))
		var rough: float = float(cfg.get_value(section, "roughness", 0.7))
		var metal: float = float(cfg.get_value(section, "metallic", 0.0))
		var flex: bool = bool(cfg.get_value(section, "flexible", true))
		var sag: float = float(cfg.get_value(section, "sag_amount", 0.3))
		var entry: Dictionary = {
			"label": label,
			"radius_m": radius,
			"color": Color(cr, cg, cb, 1.0),
			"roughness": rough,
			"metallic": metal,
			"flexible": flex,
			"sag_amount": sag,
		}
		if cfg.has_section_key(section, "ground_drape"):
			entry["ground_drape"] = bool(cfg.get_value(section, "ground_drape", false))
		if cfg.has_section_key(section, "is_light"):
			entry["is_light"] = bool(cfg.get_value(section, "is_light", false))
		if cfg.has_section_key(section, "bulb_spacing_m"):
			entry["bulb_spacing_m"] = float(cfg.get_value(section, "bulb_spacing_m", 0.0))
		if cfg.has_section_key(section, "watts_per_m"):
			entry["watts_per_m"] = float(cfg.get_value(section, "watts_per_m", 0.0))
		if cfg.has_section_key(section, "resistance_ohm_per_m"):
			entry["resistance_ohm_per_m"] = float(cfg.get_value(section, "resistance_ohm_per_m", 0.0))
		if cfg.has_section_key(section, "ampacity_a"):
			entry["ampacity_a"] = float(cfg.get_value(section, "ampacity_a", 0.0))
		if cfg.has_section_key(section, "nominal_volts"):
			entry["nominal_volts"] = float(cfg.get_value(section, "nominal_volts", 120.0))
		if cfg.has_section_key(section, "inner_diameter_m"):
			entry["inner_diameter_m"] = float(cfg.get_value(section, "inner_diameter_m", 0.0))
		if cfg.has_section_key(section, "hw_c"):
			entry["hw_c"] = float(cfg.get_value(section, "hw_c", 150.0))
		if cfg.has_section_key(section, "max_flow_lpm"):
			entry["max_flow_lpm"] = float(cfg.get_value(section, "max_flow_lpm", 0.0))
		if cfg.has_section_key(section, "burst_pressure_psi"):
			entry["burst_pressure_psi"] = float(cfg.get_value(section, "burst_pressure_psi", 0.0))
		if cfg.has_section_key(section, "conceptual"):
			entry["conceptual"] = bool(cfg.get_value(section, "conceptual", false))
		if cfg.has_section_key(section, "emissive"):
			entry["emissive"] = bool(cfg.get_value(section, "emissive", false))
		if cfg.has_section_key(section, "emission_energy"):
			entry["emission_energy"] = float(cfg.get_value(section, "emission_energy", 1.0))
		if cfg.has_section_key(section, "light_color_r"):
			entry["light_color"] = Color(
				float(cfg.get_value(section, "light_color_r", 1.0)),
				float(cfg.get_value(section, "light_color_g", 1.0)),
				float(cfg.get_value(section, "light_color_b", 0.85)),
				1.0)
		_extra[section] = entry


static func all_types() -> Array:
	_ensure_loaded()
	var keys: Array = BUILTIN.keys()
	for k: String in _extra.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	return keys


static func has_type(type_id: String) -> bool:
	_ensure_loaded()
	return BUILTIN.has(type_id) or _extra.has(type_id)


static func type_meta(type_id: String) -> Dictionary:
	_ensure_loaded()
	var meta: Dictionary
	if BUILTIN.has(type_id):
		meta = (BUILTIN[type_id] as Dictionary).duplicate(true)
	elif _extra.has(type_id):
		meta = (_extra[type_id] as Dictionary).duplicate(true)
	else:
		meta = (BUILTIN["garden_hose"] as Dictionary).duplicate(true)
	# User-tuned style defaults (glow / thickness / routing) from the library.
	ConduitStylePresets.apply_defaults_to_meta(type_id, meta)
	return meta


static func display_name(type_id: String) -> String:
	return str(type_meta(type_id).get("label", type_id.capitalize()))


## True when the conduit kind carries electrical power (has a loop resistance).
static func is_electrical_type(type_id: String) -> bool:
	return type_meta(type_id).has("resistance_ohm_per_m")


## True when the conduit kind carries fluid (has a hydraulic inner diameter).
static func is_fluid_type(type_id: String) -> bool:
	return type_meta(type_id).has("inner_diameter_m")


## True when the conduit kind is itself a light source (LED strip/fairy/patio).
static func is_light_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("is_light", false))


## True when flexible slack should drape onto the ground instead of hanging.
static func is_ground_drape_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("ground_drape", false))


## True for glowing conceptual flow overlays (not physical cord/pipe).
static func is_conceptual_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("conceptual", false))


## Hang-edit UX (hover sphere + LMB-drag pins + multi-span catenary).
## v1: extension cords + patio string lights only.
static func supports_hang_edit(type_id: String) -> bool:
	if type_id.is_empty():
		return false
	if type_id == "led_patio":
		return true
	return type_id.begins_with("extension_cord")


## True when a hang-edit connection has committed mid pins — mesh should
## sag span-to-span (not whole-run ground-snake).
static func conn_uses_hang_sag(conn: Dictionary) -> bool:
	var type_id := derive_type_for_connection(conn)
	if not supports_hang_edit(type_id):
		return false
	if not bool(conn.get("route_locked", false)):
		return false
	return not (conn.get("route_3d", []) as Array).is_empty()


## Nominal size (inches) for kit-backed pipes. Style `pipe_size_in` overrides default.
static func pipe_size_in(type_id: String, style: Dictionary = {}) -> float:
	var meta := type_meta(type_id)
	var fallback := float(meta.get("default_pipe_size_in", 0.0))
	var raw := float(style.get("pipe_size_in", fallback))
	if raw < 0.05:
		raw = fallback
	if raw < 0.05:
		return 0.0
	var family := str(meta.get("pipe_kit_family", ""))
	if family == CulvertKit.FAMILY:
		return CulvertKit.nearest_size_in(raw)
	return PipeKit.nearest_size_in(raw)


## Sizes offered in the style modal for a kit family.
static func pipe_kit_sizes_in(type_id: String) -> Array:
	if uses_culvert_kit(type_id):
		return CulvertKit.SIZES_IN.duplicate()
	if uses_pipe_kit(type_id):
		return PipeKit.SCH40_SIZES_IN.duplicate()
	return []


## Physical fittings kit id (e.g. "us_sch40_2_5" / "pe_culvert_8"), or "".
## Pass conduit_style so size overrides resolve to the correct kit.
static func pipe_kit_id(type_id: String, style: Dictionary = {}) -> String:
	var meta := type_meta(type_id)
	var family := str(meta.get("pipe_kit_family", ""))
	if family.is_empty():
		return str(meta.get("pipe_kit_id", ""))
	var sz := pipe_size_in(type_id, style)
	if sz < 0.05:
		return ""
	if family == CulvertKit.FAMILY:
		return CulvertKit.kit_id_for_size(sz)
	return PipeKit.kit_id_for_size(family, sz)


static func pipe_kit_family(type_id: String) -> String:
	return str(type_meta(type_id).get("pipe_kit_family", ""))


static func uses_pipe_kit(type_id: String) -> bool:
	var meta := type_meta(type_id)
	if not str(meta.get("pipe_kit_family", "")).is_empty():
		return true
	return not str(meta.get("pipe_kit_id", "")).is_empty()


## Display label including nominal size when kit-backed + style known.
static func display_name_with_size(type_id: String, style: Dictionary = {}) -> String:
	var base := display_name(type_id)
	if not uses_pipe_kit(type_id):
		return base
	var sz := pipe_size_in(type_id, style)
	if sz < 0.05:
		return base
	var label := CulvertKit.size_label(sz) if uses_culvert_kit(type_id) \
			else PipeKit.size_label(sz)
	return "%s %s" % [base, label]


## Kit pipe pin-edit (IK elbows) — Sch40 PVC/ABS only. Culvert uses flex pins.
static func supports_pipe_pin_edit(type_id: String) -> bool:
	return uses_pipe_kit(type_id) and not uses_culvert_kit(type_id)


## Waypoint pin spheres + surface aim for physical tubes that aren't hang-cords
## or kit pipes — PEX, garden hose, PVC, Romex, ducting, DC solar, etc.
## Conceptual dashed flow stays auto-only (no IK orbs).
static func supports_flex_pin_edit(type_id: String) -> bool:
	if type_id.is_empty() or is_conceptual_type(type_id):
		return false
	if supports_hang_edit(type_id) or supports_pipe_pin_edit(type_id):
		return false
	return not type_meta(type_id).is_empty()


## Shared gate for hang cords, kit pipes, and flex/rigid tubes (gizmos / LMB drag).
static func supports_pin_edit(type_id: String) -> bool:
	return supports_hang_edit(type_id) or supports_pipe_pin_edit(type_id) \
			or supports_flex_pin_edit(type_id)


## Dull matte Sch40 plastic for procedural straights + GLB elbows.
## PVC = chalky white, ABS = matte black — no wet clearcoat / night glow.
static func make_pipe_kit_material(type_id: String, tint: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var mat := make_material(type_id, tint)
	mat.metallic = 0.0
	mat.roughness = clampf(maxf(mat.roughness, 0.58), 0.55, 0.85)
	# Tiny clearcoat only — high clearcoat + sky reflection washed out day/night.
	var cc := float(type_meta(type_id).get("clearcoat", 0.0))
	if cc > 0.02:
		mat.clearcoat_enabled = true
		mat.clearcoat = minf(cc, 0.10)
		mat.clearcoat_roughness = 0.55
	else:
		mat.clearcoat_enabled = false
	mat.emission_enabled = false
	mat.emission_energy_multiplier = 0.0
	# Solid tube — double-sided lit both faces as bright (looked self-glowing).
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return mat


## True for rigid kinds that should use ortho / 45° elbow routing.
static func is_rigid_type(type_id: String) -> bool:
	return not bool(type_meta(type_id).get("flexible", true))


static func is_flexible_type(type_id: String) -> bool:
	return bool(type_meta(type_id).get("flexible", true)) \
			and not is_conceptual_type(type_id)


## Pipes-screensaver default (PVC / duct / conceptual via route_mode).
## Legacy metro_ground flag still counts so old presets keep routing.
static func is_pipes_type(type_id: String) -> bool:
	var meta := type_meta(type_id)
	var mode := normalize_route_mode(str(meta.get("route_mode", "")))
	if mode == "pipes" or mode == "culvert":
		return true
	if mode == "ortho" or mode == "direct":
		return false
	return bool(meta.get("metro_ground", false)) or is_conceptual_type(type_id)


## Corrugated PE culvert family (ring MultiMesh + large-radius router).
static func uses_culvert_kit(type_id: String) -> bool:
	return pipe_kit_family(type_id) == CulvertKit.FAMILY


## Legacy alias — pipes replaced metro corridors.
static func is_metro_ground_type(type_id: String) -> bool:
	return is_pipes_type(type_id)


## Standard fitting bend angle (deg) for a pipe kind. 0 → classic axis-only 90°
## elbows; >0 → every auto horizontal bend snaps to that angle (real PVC/ABS look).
## A style override (conn.conduit_style.fitting_step_deg) wins over the kind default.
static func fitting_step_deg(type_id: String, style_override: Dictionary = {}) -> float:
	var raw: float = float(style_override.get("fitting_step_deg",
		type_meta(type_id).get("fitting_step_deg", 0.0)))
	if raw <= 0.5:
		return 0.0
	return ConduitPipesRouter.snap_fitting_angle(raw)


## Normalize route_mode; legacy "metro" → "pipes".
##   pipes    — rigid straight sections + standard-angle elbows (PVC/duct).
##   culvert  — corrugated PE: large-radius sweeps, ring segments (no fittings).
##   ortho    — clean axis-aligned + 45° runs (in-wall wiring / data / trays).
##   taut     — straight point-to-point, no sag (LED strip / tensioned cable).
##   catenary — hangs overhead in a sag between two points (patio lights / drops).
##   drape / "" (direct) — flexible; drapes to ground if ground_drape, else sags.
static func normalize_route_mode(mode: String) -> String:
	if mode == "metro" or mode == "metro_ground":
		return "pipes"
	return mode


## Route-mode options for the conduit style picker (id → label).
static func route_mode_options() -> Array:
	return [
		{"id": "", "label": "Auto (by cord type)"},
		{"id": "pipes", "label": "Rigid pipe (elbows)"},
		{"id": "culvert", "label": "Culvert (PE wide arcs)"},
		{"id": "ortho", "label": "Right-angle (walls/trays)"},
		{"id": "taut", "label": "Taut (straight, no sag)"},
		{"id": "catenary", "label": "Overhead (hanging sag)"},
		{"id": "direct", "label": "Free drape"},
	]


## Mesh-sampling overrides implied by a route_mode (merged over the kind's own
## style before building the tube). taut → straight, no sag; catenary → force an
## overhead parabolic hang (never drape flat to the ground).
static func mesh_style_override(route_mode: String) -> Dictionary:
	match normalize_route_mode(route_mode):
		"taut":
			return {"flexible": false, "sag_amount": 0.0, "ground_drape": false}
		"catenary":
			return {"flexible": true, "ground_drape": false, "sag_amount": 0.32}
		_:
			return {}


## Suggested physical kind for a connection (used by the conduit picker "auto physical").
static func suggested_physical_type(conn: Dictionary) -> String:
	var pol: String = str(conn.get("polarity", ""))
	if pol in ["ac", "load", "positive", "negative", "smart_battery"]:
		return "extension_cord"
	var rtype: String = str(conn.get("resource_type", ""))
	if not rtype.is_empty() and RESOURCE_DEFAULTS.has(rtype):
		return str(RESOURCE_DEFAULTS[rtype])
	if not rtype.is_empty():
		return "garden_hose"
	return "extension_cord"


## Physical kind used for LOSS PHYSICS (Hazen-Williams friction/pressure drop),
## as opposed to `derive_type_for_connection`'s visual default (unstyled wires
## render as the "conceptual_flow" glow, which carries no hydraulic diameter).
## Respects an explicit conduit_type override same as derive_type_for_connection;
## otherwise falls back to the resource-kind-inferred physical pipe/cord
## (`suggested_physical_type`) so an unstyled water/hot-water/etc. connection
## still sees realistic friction loss instead of silently bypassing it.
static func physical_type_for_connection(conn: Dictionary) -> String:
	var override: String = str(conn.get("conduit_type", ""))
	if not override.is_empty() and has_type(override):
		return override
	return suggested_physical_type(conn)


## Tint for conceptual flows from polarity / resource_type.
static func flow_tint_for_connection(conn: Dictionary) -> Color:
	var rtype: String = str(conn.get("resource_type", ""))
	if not rtype.is_empty():
		return ResourceKinds.wire_color(rtype)
	var pol: String = str(conn.get("polarity", ""))
	match pol:
		"positive", "pv":
			return Color(0.847, 0.329, 0.329, 1.0)
		"negative":
			return Color(0.45, 0.45, 0.48, 1.0)
		"ac", "ac_240":
			return Color(0.941, 0.678, 0.306, 1.0)
		"load":
			return Color(0.941, 0.820, 0.282, 1.0)
		"smart_battery":
			return Color(0.063, 0.722, 0.506, 1.0)
		"resource":
			return Color(0.580, 0.639, 0.722, 1.0)
		_:
			return Color(0.35, 0.85, 1.0, 1.0)


## Derive conduit type from a graph connection dict (respects conduit_type override).
## Empty override → conceptual glow; light presets stamp conduit_type on connect.
static func derive_type_for_connection(conn: Dictionary) -> String:
	var override: String = str(conn.get("conduit_type", ""))
	if not override.is_empty() and has_type(override):
		return override
	return "conceptual_flow"


static func make_material(type_id: String, tint: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var meta: Dictionary = type_meta(type_id)
	var mat := StandardMaterial3D.new()
	var col: Color = meta.get("color", Color.WHITE) as Color
	if tint.a > 0.01:
		col = tint
	mat.albedo_color = col
	mat.roughness = float(meta.get("roughness", 0.7))
	mat.metallic = float(meta.get("metallic", 0.0))
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Elev/Site CT: show conduits through the opaque soil bowl (same as flow shader).
	mat.no_depth_test = true
	mat.render_priority = 16
	# Clearcoat gives plastics (PVC/PEX/ethernet jacket) a wet plastic sheen that
	# distinguishes them from matte fabric/rubber cords.
	var cc := float(meta.get("clearcoat", 0.0))
	if cc > 0.001:
		mat.clearcoat_enabled = true
		mat.clearcoat = cc
		mat.clearcoat_roughness = 0.12
	if bool(meta.get("emissive", false)) or bool(meta.get("conceptual", false)):
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = float(meta.get("emission_energy", 2.0))
		mat.roughness = minf(mat.roughness, 0.35)
	elif bool(meta.get("jacket_emissive", false)):
		# Outdoor yellow cord: mild self-illumination so it never reads as black.
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.35
	return mat


static func fitting_color(type_id: String) -> Color:
	var meta: Dictionary = type_meta(type_id)
	if meta.has("fitting_color"):
		return meta["fitting_color"] as Color
	return meta.get("color", Color(0.7, 0.7, 0.7, 1.0)) as Color


static func make_fitting_material(type_id: String) -> StandardMaterial3D:
	var meta: Dictionary = type_meta(type_id)
	var mat := StandardMaterial3D.new()
	var col := fitting_color(type_id)
	mat.albedo_color = col
	mat.roughness = 0.45
	mat.metallic = 0.15
	mat.no_depth_test = true
	mat.render_priority = 17
	if bool(meta.get("plug_emissive", false)):
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 1.8
	return mat


const FLOW_SHADER_PATH := "res://core/conduits/conduit_flow.gdshader"
static var _flow_shader: Shader = null


static func _ensure_flow_shader() -> Shader:
	if _flow_shader == null:
		_flow_shader = load(FLOW_SHADER_PATH) as Shader
	return _flow_shader


## Flow-capable material (conceptual always; physical when flow_glow on).
static func make_flow_material(type_id: String, tint: Color = Color(0, 0, 0, 0),
		flow_strength: float = 0.85, flow_speed: float = 1.2) -> ShaderMaterial:
	var sh := _ensure_flow_shader()
	var mat := ShaderMaterial.new()
	if sh != null:
		mat.shader = sh
	apply_flow_material_params(mat, type_id, tint, flow_strength, flow_speed)
	return mat


## Update an existing flow ShaderMaterial in-place (avoids alloc on rebuild).
static func apply_flow_material_params(mat: ShaderMaterial, type_id: String,
		tint: Color = Color(0, 0, 0, 0), flow_strength: float = 0.85,
		flow_speed: float = 1.2, emission_boost: float = -1.0) -> void:
	if mat == null:
		return
	var sh := _ensure_flow_shader()
	if sh != null and mat.shader != sh:
		mat.shader = sh
	var meta: Dictionary = type_meta(type_id)
	var col: Color = meta.get("color", Color.WHITE) as Color
	if tint.a > 0.01:
		col = tint
	var conceptual := 1.0 if is_conceptual_type(type_id) else 0.0
	mat.set_shader_parameter("base_color", col)
	mat.set_shader_parameter("flow_color", col.lightened(0.45))
	mat.set_shader_parameter("flow_speed", flow_speed)
	mat.set_shader_parameter("flow_strength", flow_strength)
	mat.set_shader_parameter("pulse", 0.25 if conceptual > 0.5 else 0.15)
	mat.set_shader_parameter("conceptual", conceptual)
	var boost := emission_boost
	if boost < 0.0:
		boost = float(meta.get("emission_energy", 0.55 if conceptual > 0.5 else 2.0))
	mat.set_shader_parameter("emission_boost", boost)


## Stock cord/hose segments for a run length (ceil(length / max_segment_m)).
static func segment_count_for_length(type_id: String, length_m: float) -> int:
	var max_seg: float = float(type_meta(type_id).get("max_segment_m", 0.0))
	if max_seg <= 0.01 or length_m <= 0.01:
		return 1
	return maxi(1, int(ceil(length_m / max_seg)))


## Resolve per-conn visible_3d tri-state against a global default.
## missing/null key → follow global for physical kinds; conceptual stays
## hidden unless the user forces visible_3d on. true/false force always wins.
## Direct-intake links (siphon pond→module) stay hidden unless the user
## explicitly forces visible_3d on — even after "Make physical".
## Optional `model` lets hand-drawn wires to a direct_intake port hide without
## needing a stamped conn flag.
static func resolve_visible_3d(conn: Dictionary, global_visible: bool,
		model: Object = null) -> bool:
	if conn.has("visible_3d") and conn.get("visible_3d") != null:
		return bool(conn.get("visible_3d"))
	if is_direct_intake_connection(conn, model):
		return false
	var type_id := derive_type_for_connection(conn)
	if is_conceptual_type(type_id):
		return false
	return global_visible


## True when either endpoint handle is a direct-intake port (siphon water in).
static func is_direct_intake_connection(conn: Dictionary, model: Object = null) -> bool:
	if bool(conn.get("direct_intake", false)):
		return true
	if model == null or not model.has_method("get_item"):
		return false
	for end_key in ["target_item_id", "source_item_id"]:
		var handle_key := "target_handle_id" if end_key == "target_item_id" \
				else "source_handle_id"
		var iid := str(conn.get(end_key, ""))
		var hid := str(conn.get(handle_key, ""))
		if iid.is_empty() or hid.is_empty():
			continue
		var item: Dictionary = model.get_item(iid)
		if item.is_empty():
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var inputs: Array = specs.get("inputs", []) as Array
		# res_in_N → inputs[N]
		if hid.begins_with("res_in_"):
			var idx_s := hid.trim_prefix("res_in_").split("_")[0]
			if idx_s.is_valid_int():
				var idx := int(idx_s)
				if idx >= 0 and idx < inputs.size():
					var inp: Dictionary = inputs[idx] as Dictionary
					if bool(inp.get("direct_intake", false)):
						return true
		elif hid == "input" and inputs.size() > 0 \
				and bool((inputs[0] as Dictionary).get("direct_intake", false)):
			return true
	return false


## Resolve per-conn flow_glow tri-state. Quiet by default for all kinds;
## global toggle or per-conn force opts into the marching pulse.
static func resolve_flow_glow(conn: Dictionary, _type_id: String,
		global_flow_glow: bool) -> bool:
	if conn.has("flow_glow") and conn.get("flow_glow") != null:
		return bool(conn.get("flow_glow", false))
	return global_flow_glow


## Closest point on a polyline to a ray; returns {distance, point, segment_i, t}.
static func ray_polyline_pick(origin: Vector3, direction: Vector3,
		samples: PackedVector3Array, max_dist: float = 0.25) -> Dictionary:
	var miss := {"distance": INF, "point": Vector3.ZERO, "segment_i": -1, "t": 0.0}
	if samples.size() < 2 or direction.length_squared() < 1e-12:
		return miss
	var dir := direction.normalized()
	var best_d := max_dist
	var best := miss.duplicate()
	for i: int in range(samples.size() - 1):
		var a: Vector3 = samples[i]
		var b: Vector3 = samples[i + 1]
		var hit := _ray_segment_closest(origin, dir, a, b)
		if float(hit.get("distance", INF)) < best_d:
			best_d = float(hit["distance"])
			best = {
				"distance": best_d,
				"point": hit["point"],
				"segment_i": i,
				"t": float(hit.get("t", 0.0)),
			}
	return best


static func _ray_segment_closest(origin: Vector3, dir: Vector3,
		a: Vector3, b: Vector3) -> Dictionary:
	# Closest approach between ray (origin + s*dir, s>=0) and segment (a + t*(b-a)).
	var u := dir
	var v := b - a
	var w0 := origin - a
	var aa := u.dot(u)
	var bb := v.dot(v)
	var cc := u.dot(v)
	var d := u.dot(w0)
	var e := v.dot(w0)
	var denom := aa * bb - cc * cc
	var s: float
	var t: float
	if absf(denom) < 1e-10:
		s = 0.0
		t = clampf(e / bb if bb > 1e-10 else 0.0, 0.0, 1.0)
	else:
		s = (cc * e - bb * d) / denom
		t = (aa * e - cc * d) / denom
		s = maxf(s, 0.0)
		t = clampf(t, 0.0, 1.0)
	var p_ray := origin + u * s
	var p_seg := a + v * t
	return {"distance": p_ray.distance_to(p_seg), "point": p_seg, "t": t}


## Sum Euclidean length of a polyline (control points or sampled path).
static func polyline_length_m(points: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## Parse route_3d waypoint dicts into world positions.
## When `resolve_pins` is true (default) and `tree` is provided, pin_path
## entries re-resolve to the live collider (legacy wall-socket pinning).
## Hang-edit cords must pass resolve_pins=false — prop colliders often sit at
## the mesh origin (StarShade near ground), which would yank pins off roofs.
static func waypoints_to_vectors(
		route_3d: Array, tree: SceneTree = null, resolve_pins: bool = true) -> Array:
	var out: Array = []
	for wp: Variant in route_3d:
		if wp is Vector3:
			out.append(wp)
		elif wp is Dictionary:
			var d: Dictionary = wp as Dictionary
			var pin := str(d.get("pin_path", ""))
			if resolve_pins and tree != null and not pin.is_empty():
				var node: Node = tree.root.get_node_or_null(NodePath(pin))
				if node is Node3D and is_instance_valid(node):
					out.append((node as Node3D).global_position)
					continue
			out.append(Vector3(
				float(d.get("x", 0.0)),
				float(d.get("y", 0.0)),
				float(d.get("z", 0.0)),
			))
	return out


## Drop pin_path keys so hang pins stay at authored world XYZ after rebuild.
static func strip_hang_pin_paths(route_3d: Array) -> Array:
	var out: Array = []
	for w: Variant in route_3d:
		if typeof(w) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (w as Dictionary).duplicate(true)
		d.erase("pin_path")
		out.append(d)
	return out


## Serialize a world position (+ optional pin path) for GraphModel storage.
static func waypoint_dict(pos: Vector3, pin_path: String = "") -> Dictionary:
	var d: Dictionary = {"x": pos.x, "y": pos.y, "z": pos.z}
	if not pin_path.is_empty():
		d["pin_path"] = pin_path
	return d


## Site-plan metre waypoint {x, z} helpers.
static func site_waypoint_dict(site_xz: Vector2) -> Dictionary:
	return {"x": site_xz.x, "z": site_xz.y}


static func site_waypoints_to_vectors(site_waypoints: Array) -> Array:
	var out: Array = []
	for wp: Variant in site_waypoints:
		if wp is Vector2:
			out.append(wp)
		elif wp is Dictionary:
			out.append(Vector2(
				float(wp.get("x", 0.0)),
				float(wp.get("z", wp.get("y", 0.0)))))
	return out


## Ensure v4 conduit fields exist on a connection dict (in-place migration).
static func migrate_connection_conduit_fields(conn: Dictionary) -> void:
	if not conn.has("route_3d"):
		conn["route_3d"] = []
	if not conn.has("conduit_type"):
		conn["conduit_type"] = ""
	if not conn.has("route_length_m"):
		conn["route_length_m"] = 0.0
	if not conn.has("site_waypoints"):
		conn["site_waypoints"] = []
	if not conn.has("route_locked"):
		conn["route_locked"] = false
	# Optional per-connection look overrides (from Conduit Style modal).
	if not conn.has("conduit_style"):
		conn["conduit_style"] = {}

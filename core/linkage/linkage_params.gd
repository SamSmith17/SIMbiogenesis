class_name LinkageParams
extends RefCounted
## Parameter model for the LinkageLab scissor-linkage designer (GDScript port).
##
## Mirrors the web app's `js/linkage/app-state.js` state object (structure +
## mode + hardware subsets in scope). All lengths are IMPERIAL and match the
## web app exactly: beam lengths in FEET (`h_length_ft`/`v_length_ft`),
## everything else in INCHES. The solver stays in inches so results can be
## pinned 1:1 against JavaScript reference values; conversion to metres
## happens only in the mesh builder (LinkageStructureBuilder).
##
## `to_config()` / `from_config()` round-trip the web app's v30 config JSON
## (see `config-persistence.js:getConfigSnapshot`), so designs exported from
## the LinkageLab web app load directly and vice versa.

# --- Structure ---
var modules: int = 8
var h_length_ft: float = 8.0
var v_length_ft: float = 8.0
var pivot_pct: float = 41.5
var hoberman_ang: float = 0.0        # degrees (angulated / Hoberman bend)
var pivot_ang: float = 0.0           # degrees (asymmetric pivot offset)

var h_stack_count: int = 2
var v_stack_count: int = 3
var v_stack_reverse: bool = false

var offset_top_in: float = 1.5
var offset_bot_in: float = 1.5
var vert_end_offset: float = 1.5
var h_stack_gap: float = 0.0
var v_stack_gap: float = 0.0

var h_beam_w: float = 3.5
var h_beam_t: float = 1.5
var v_beam_w: float = 1.5
var v_beam_t: float = 3.5
var v_beam_dimensions_linked: bool = true
var v_beam_inner_w: float = 1.5
var v_beam_inner_t: float = 3.5
var v_beam_outer_w: float = 1.5
var v_beam_outer_t: float = 3.5

# --- Bracket (drives pivot height => structure height; also simple visual) ---
var bracket_width: float = 2.0
var bracket_depth: float = 3.0
var bracket_height: float = 3.0
var bracket_wall_thickness: float = 0.25
var bracket_inner_width: float = 1.5
var bracket_hole_diameter: float = 0.375
var bracket_hole_distance: float = 1.5

# --- Bolts (simple visual cylinders) ---
var bolt_diameter: float = 0.375
var v_bolt_length: float = 3.0
var v_bolt_inner_length: float = 3.0
var v_bolt_outer_length: float = 2.0
var h_bolt_length: float = 3.0
var h_pivot_bolt_length: float = 4.0
var v_bolt_auto: bool = true
var h_bolt_auto: bool = true
var h_pivot_bolt_auto: bool = true

# --- Fold / visibility ---
var fold_angle: float = 135.4 * PI / 180.0   # radians
var show_brackets: bool = true
var show_bolts: bool = false
## Opt-in high-detail hardware. When true, the parametric assembly stacks own
## the stack gaps and bracket dimensions instead of the sidebar values above
## (see LinkageHardwareSpacing). It defaults FALSE and must stay that way: the
## solver's pinned reference values were generated against a hardware-disabled
## run of the JS app (`tools/linkage_reference.mjs` mocks the hw* globals off),
## so flipping this default silently invalidates every pin in the selftest.
var show_hardware_full_detail: bool = false

# --- Orientation / mode ---
var orientation: String = "horizontal"       # "horizontal" (cylinder) | "vertical" (arch)
var arch_cap_uprights: bool = false
var use_fixed_beams: bool = false
var arch_flip_vertical: bool = false
var arch_rotation: float = 0.0               # degrees
var array_count: int = 1                     # tunnel/tube duplicates (arch only)
var structure_rotation: float = 0.0          # degrees about Y (visual only)

# --- Animation / visibility angles (degrees; -1.0 sentinel = null/auto) ---
var animation_stop_angle: float = -1.0       # close limit (deg), <0 = use closed angle
var min_fold_angle_deg: float = -1.0         # user override (deg), <0 = auto (V-beam contact)
var radial_visible_angle: float = 90.0
var rcp_visible_angle: float = 90.0
var panels_visible_angle: float = -1.0       # <0 = at closed/deploy angle

# --- Support / reciprocal beams (Phase 4) — mirrors state.supportBeams ---
var support_beams: Dictionary = default_support_beams()

# --- Solar panels (Phase 4) — mirrors state.solarPanels ---
var solar_panels: Dictionary = default_solar_panels()

# --- Costs (BOM) — mirrors the web app's cost* state fields ---
var costs: Dictionary = default_costs()

# --- Stack washers (BOM only; the solver never sees them) ---
var washers: Dictionary = default_washers()

## Parametric hardware stacks per joint. Stored in the web app's own camelCase
## shape — see LinkageHardware's class docstring for why.
var hardware_assemblies: Dictionary = LinkageHardware.default_assemblies()

const INCHES_PER_FOOT := 12.0
const INCHES_PER_METER := 39.37007874015748


static func default_support_beams() -> Dictionary:
	return {
		"enabled": true,
		"show_radial": true,
		"length": 120.0,
		"width": 1.5,
		"thickness": 3.5,
		"rotation": 0.0,
		"offset_h": -46.5,
		"offset_v": -6.8,
		"fold_angle": 0.0,
		"parallel_enabled": true,
		"parallel_length": 96.0,
		"parallel_width": 2.5,
		"parallel_thickness": 1.5,
		"parallel_fold_angle": 0.0,
		"parallel_swing_angle": 0.0,
		"parallel_v_offset": -1.66,
		"parallel_offset_v": 4.5,
		"anchor_dist": 20.0,
		"rcp_end_offset": 0.0,
	}


static func default_panel_section(enabled: bool) -> Dictionary:
	return {
		"enabled": enabled,
		"panel_length": 65.0,
		"panel_width": 39.0,
		"panel_thickness": 1.5,
		"rated_watts": 250.0,
		"voc": 37.5,
		"vmp": 31.2,
		"isc": 8.8,
		"imp": 8.1,
		"padding_x": 2.0,
		"padding_y": 2.0,
		"grid_rows": 2,
		"grid_cols": 2,
		"panel_lift": 0.0,
		"weight": 45.0,
	}


static func default_solar_panels() -> Dictionary:
	return {
		"enabled": false,
		"top_panels": default_panel_section(true),
		"side_panels": default_panel_section(false),
		"layout_mode": "rectangular",   # rectangular | radial | spiral
		"grid_rotation": 0.0,
		"radial_count": 8,
		"radial_offset": 0.0,
		"radial_rotation": 0.0,
		"radial_lateral_offset": 0.0,
		"pinwheel_angle": 0.0,
		"spiral_arm_count": 2,
		"spiral_secondary_enabled": true,
		"spiral_secondary_radial_offset": 24.0,
		"spiral_secondary_lateral_offset": 0.0,
		"spiral_secondary_pinwheel": 0.0,
		"spiral_secondary_rotation": 0.0,
		"spiral_arm_radial_step": 0.0,
		"spiral_arm_lateral_step": 0.0,
		"spiral_arm_pinwheel_step": 0.0,
		"spiral_arm_rotation_step": 0.0,
		"arch_wall_faces": [],          # empty = all faces enabled
		"arch_panel_offset": 2.0,
		"arch_panel_slide": 0.5,
		"arch_panel_separation": 0.0,
	}


## Per-item prices in USD (`app-state.js:58-98`). `auto_lumber` prices beams by
## volume against `ref_beam` instead of the flat `h_beam`/`v_beam` figures.
static func default_costs() -> Dictionary:
	return {
		"h_beam": 12.00,
		"v_beam": 10.00,
		"bolt": 0.75,
		"bolt_v_inner": 0.75,
		"bolt_v_outer": 0.50,
		"bolt_h": 0.75,
		"bolt_h_pivot": 0.75,
		"washer_v": 0.10,
		"washer_h": 0.10,
		"bracket": 5.00,
		"solar_panel": 150.00,
		"auto_lumber": true,
		# 2x4 nominal (1.5" x 3.5" actual) x 8' at a typical retail price.
		"ref_beam": {"width": 3.5, "thickness": 1.5, "length_ft": 8.0, "price": 5.48},
	}


## Stack washers (`app-state.js:64-75`). These are a BOM/cost concern only —
## no solver geometry reads them. NOTE both enables default TRUE upstream, so a
## stock design carries washer lines out of the box; that is faithful, not a bug.
static func default_washers() -> Dictionary:
	return {
		"v_enabled": true,
		"v_id": 0.4375,
		"v_od": 1.0,
		"v_thickness": 0.0,     # 0 = auto-synced with v_stack_gap
		"v_auto": true,
		"h_enabled": true,
		"h_id": 0.4375,
		"h_od": 1.0,
		"h_thickness": 0.0,     # 0 = auto-synced with h_stack_gap
		"h_auto": true,
	}


func duplicate_params() -> LinkageParams:
	var p := LinkageParams.new()
	p.from_config(to_config())
	return p


# ---------------------------------------------------------------------------
# Derived helpers (port of beam-bolt-helpers.js — pure subset)
# ---------------------------------------------------------------------------

func h_active_in() -> float:
	return h_length_ft * INCHES_PER_FOOT - offset_top_in - offset_bot_in


func needs_split_v_beam_dimensions() -> bool:
	return v_stack_count == 3


func is_v_beam_dimensions_linked() -> bool:
	if not needs_split_v_beam_dimensions():
		return true
	return v_beam_dimensions_linked


func is_v_stack_inner_beam_index(stack_index: int) -> bool:
	return v_stack_count == 3 and stack_index == int(v_stack_count / 2.0)


func v_beam_dims_for_stack_index(stack_index: int) -> Dictionary:
	if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
		return {"w": v_beam_w, "t": v_beam_t}
	if is_v_stack_inner_beam_index(stack_index):
		return {"w": v_beam_inner_w, "t": v_beam_inner_t}
	return {"w": v_beam_outer_w, "t": v_beam_outer_t}


func v_beam_dims_for_pivot(is_inner_pivot: bool) -> Dictionary:
	if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
		return {"w": v_beam_w, "t": v_beam_t}
	if is_inner_pivot:
		return {"w": v_beam_inner_w, "t": v_beam_inner_t}
	return {"w": v_beam_outer_w, "t": v_beam_outer_t}


func v_stack_beam_widths() -> Array:
	var widths: Array = []
	for i in range(v_stack_count):
		widths.append(float(v_beam_dims_for_stack_index(i)["w"]))
	return widths


func v_stack_total_thickness(widths: Array = [], gap_override: float = NAN) -> float:
	var gap := v_stack_gap if is_nan(gap_override) else gap_override
	if widths.is_empty():
		if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
			return v_stack_count * v_beam_w + maxf(0.0, v_stack_count - 1) * gap
		widths = v_stack_beam_widths()
	var total := 0.0
	for w in widths:
		total += float(w)
	if v_stack_count > 1:
		total += (v_stack_count - 1) * gap
	return total


func v_stack_beam_center_offset(stack_index: int, widths: Array = []) -> float:
	var gap := v_stack_gap
	if widths.is_empty():
		if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
			var total_thick := v_stack_count * v_beam_w + (v_stack_count - 1) * gap
			var start_offset := -total_thick / 2.0 + v_beam_w / 2.0
			return start_offset + stack_index * (v_beam_w + gap)
		widths = v_stack_beam_widths()
	var total := v_stack_total_thickness(widths, gap)
	var offset := -total / 2.0
	for i in range(stack_index):
		offset += float(widths[i]) + gap
	offset += float(widths[stack_index]) / 2.0
	return offset


func total_v_beam_width() -> float:
	if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
		return v_stack_count * v_beam_w
	var total := 0.0
	for w in v_stack_beam_widths():
		total += float(w)
	return total


func needs_split_v_bolts() -> bool:
	return v_stack_count > 2 and v_stack_count % 2 == 1


func v_bolt_stack_beam_width(sub_type: String) -> float:
	if not needs_split_v_beam_dimensions() or is_v_beam_dimensions_linked():
		var beam_count: int
		if sub_type == "inner":
			beam_count = int(ceil(v_stack_count / 2.0))
		elif sub_type == "outer":
			beam_count = int(floor(v_stack_count / 2.0))
		else:
			beam_count = v_stack_count
		return beam_count * v_beam_w
	var total := 0.0
	for i in range(v_stack_count):
		var dims := v_beam_dims_for_stack_index(i)
		if sub_type == "inner" and not is_v_stack_inner_beam_index(i):
			total += float(dims["w"])
		elif sub_type == "outer" and is_v_stack_inner_beam_index(i):
			total += float(dims["w"])
		elif sub_type != "inner" and sub_type != "outer":
			total += float(dims["w"])
	return total


func auto_v_stack_bolt_length() -> float:
	var total_beam_width := total_v_beam_width() if (needs_split_v_beam_dimensions() and not is_v_beam_dimensions_linked()) else v_stack_count * v_beam_w
	return total_beam_width + maxf(0.0, v_stack_gap) * 2.0 + 1.0


func auto_v_stack_inner_bolt_length() -> float:
	return v_bolt_stack_beam_width("inner") + maxf(0.0, v_stack_gap) + 1.0


func auto_v_stack_outer_bolt_length() -> float:
	return v_bolt_stack_beam_width("outer") + maxf(0.0, v_stack_gap) + 1.0


func auto_h_stack_bolt_length() -> float:
	return h_stack_count * h_beam_t + maxf(0.0, h_stack_gap) * 2.0 + 1.0


func auto_h_pivot_bolt_length() -> float:
	var h_stack_total := h_stack_count * h_beam_t + maxf(0.0, h_stack_gap) * (h_stack_count - 1)
	return h_stack_total + bracket_wall_thickness + 1.0


## Refresh auto-calculated bolt lengths (mirrors updateAutoBoltLengths minus
## UI/washer sync). Called by the designer whenever stack params change.
func apply_auto_bolt_lengths() -> void:
	if needs_split_v_bolts():
		v_bolt_inner_length = auto_v_stack_inner_bolt_length()
		v_bolt_outer_length = auto_v_stack_outer_bolt_length()
		v_bolt_length = auto_v_stack_bolt_length()
	elif v_bolt_auto:
		v_bolt_length = auto_v_stack_bolt_length()
	if h_bolt_auto:
		h_bolt_length = auto_h_stack_bolt_length()
	if h_pivot_bolt_auto:
		h_pivot_bolt_length = auto_h_pivot_bolt_length()


# ---------------------------------------------------------------------------
# v30 config JSON round-trip (web-app compatible)
# ---------------------------------------------------------------------------

## Snapshot as a v30 config Dictionary (`config-persistence.js:getConfigSnapshot`).
##
## `summary` is deliberately NOT emitted. It is a derived export snapshot
## (dimensions, watts) that changes with every geometry tweak, and
## `LinkageStructureBuilder.packed_spec()` keys its cache on this dict's hash —
## a derived block there would bust that cache on every fold tick.
## `LinkageBom.to_json()` writes `summary` for exports that want it.
func to_config() -> Dictionary:
	var sp: Dictionary = solar_panels
	var sb: Dictionary = support_beams
	return {
		"structure": {
			"modules": modules,
			"beamLengths": {"horizontal": h_length_ft, "vertical": v_length_ft},
			"pivotPercent": pivot_pct,
			"stackCounts": {"horizontal": h_stack_count, "vertical": v_stack_count},
			"beamDimensions": {
				"horizontalWidth": h_beam_w,
				"horizontalThickness": h_beam_t,
				"verticalWidth": v_beam_w,
				"verticalThickness": v_beam_t,
				"verticalInnerWidth": v_beam_inner_w,
				"verticalInnerThickness": v_beam_inner_t,
				"verticalOuterWidth": v_beam_outer_w,
				"verticalOuterThickness": v_beam_outer_t,
				"verticalDimensionsLinked": v_beam_dimensions_linked,
			},
			"offsets": {
				"top": offset_top_in,
				"bottom": offset_bot_in,
				"vertEnd": vert_end_offset,
				"hStackGap": h_stack_gap,
				"vStackGap": v_stack_gap,
			},
			"brackets": {
				"width": bracket_width,
				"depth": bracket_depth,
				"height": bracket_height,
				"wallThickness": bracket_wall_thickness,
				"innerWidth": bracket_inner_width,
				"holeDiameter": bracket_hole_diameter,
				"zRotation": 0.0,
			},
			"bracketDimensions": {
				"width": bracket_width,
				"depth": bracket_depth,
				"height": bracket_height,
				"wallThickness": bracket_wall_thickness,
				"innerWidth": bracket_inner_width,
				"holeDistance": bracket_hole_distance,
			},
			"bolts": {
				"diameter": bolt_diameter,
				"vStackLength": v_bolt_length,
				"hStackLength": h_bolt_length,
				"vStackAuto": v_bolt_auto,
				"hStackAuto": h_bolt_auto,
				"hPivotBoltLength": h_pivot_bolt_length,
				"hPivotBoltAuto": h_pivot_bolt_auto,
			},
			"hobermanAngle": hoberman_ang,
			"pivotAngle": pivot_ang,
			"vStackReverse": v_stack_reverse,
			"washers": {
				"vEnabled": washers["v_enabled"],
				"vID": washers["v_id"],
				"vOD": washers["v_od"],
				"vThickness": washers["v_thickness"],
				"vAuto": washers["v_auto"],
				"hEnabled": washers["h_enabled"],
				"hID": washers["h_id"],
				"hOD": washers["h_od"],
				"hThickness": washers["h_thickness"],
				"hAuto": washers["h_auto"],
			},
		},
		"mode": {
			"type": "arch" if orientation == "vertical" else "cylinder",
			"flipVertical": arch_flip_vertical,
			"rotation": arch_rotation,
			"useFixedBeams": use_fixed_beams,
			"capUprights": arch_cap_uprights,
			"arrayCount": array_count,
		},
		"foldAngle": rad_to_deg(fold_angle),
		"animationStopAngle": animation_stop_angle if animation_stop_angle >= 0.0 else null,
		"minFoldAngle": min_fold_angle_deg if min_fold_angle_deg >= 0.0 else null,
		"radialVisibleAngle": radial_visible_angle,
		"rcpVisibleAngle": rcp_visible_angle,
		"panelsVisibleAngle": panels_visible_angle if panels_visible_angle >= 0.0 else null,
		"panels": {
			"enabled": sp["enabled"],
			"topPanels": _panel_section_to_config(sp["top_panels"]),
			"sidePanels": _panel_section_to_config(sp["side_panels"]),
			"layoutMode": sp["layout_mode"],
			"gridRotation": sp["grid_rotation"],
			"positioning": {
				"lift": sp["arch_panel_offset"],
				"slide": sp["arch_panel_slide"],
				"separation": sp["arch_panel_separation"],
			},
			"radial": {
				"count": sp["radial_count"],
				"offset": sp["radial_offset"],
				"rotation": sp["radial_rotation"],
				"lateralOffset": sp["radial_lateral_offset"],
				"pinwheelAngle": sp["pinwheel_angle"],
			},
			"spiral": {
				"armCount": sp["spiral_arm_count"],
				"secondaryEnabled": sp["spiral_secondary_enabled"],
				"secondaryRadialOffset": sp["spiral_secondary_radial_offset"],
				"secondaryLateralOffset": sp["spiral_secondary_lateral_offset"],
				"secondaryPinwheel": sp["spiral_secondary_pinwheel"],
				"secondaryRotation": sp["spiral_secondary_rotation"],
				"armRadialStep": sp["spiral_arm_radial_step"],
				"armLateralStep": sp["spiral_arm_lateral_step"],
				"armPinwheelStep": sp["spiral_arm_pinwheel_step"],
				"armRotationStep": sp["spiral_arm_rotation_step"],
			},
			"enabledFaces": null if (sp["arch_wall_faces"] as Array).is_empty() else sp["arch_wall_faces"],
		},
		"supportBeams": {
			"enabled": sb["enabled"],
			"showRadial": sb.get("show_radial", true),
			"length": sb["length"],
			"width": sb["width"],
			"thickness": sb["thickness"],
			"rotation": sb["rotation"],
			"offsetH": sb["offset_h"],
			"offsetV": sb["offset_v"],
			"foldAngle": sb["fold_angle"],
			"parallelEnabled": sb["parallel_enabled"],
			"parallelLength": sb["parallel_length"],
			"parallelWidth": sb["parallel_width"],
			"parallelThickness": sb["parallel_thickness"],
			"parallelFoldAngle": sb["parallel_fold_angle"],
			"parallelSwingAngle": sb["parallel_swing_angle"],
			"parallelVOffset": sb["parallel_v_offset"],
			"parallelOffsetV": sb["parallel_offset_v"],
			"anchorDist": sb["anchor_dist"],
			"rcpEndOffset": sb["rcp_end_offset"],
		},
		"costs": {
			"hBeam": costs["h_beam"],
			"vBeam": costs["v_beam"],
			"bolt": costs["bolt"],
			"boltVInner": costs["bolt_v_inner"],
			"boltVOuter": costs["bolt_v_outer"],
			"boltH": costs["bolt_h"],
			"boltHPivot": costs["bolt_h_pivot"],
			"washerV": costs["washer_v"],
			"washerH": costs["washer_h"],
			"bracket": costs["bracket"],
			"solarPanel": costs["solar_panel"],
			"autoLumber": costs["auto_lumber"],
			"refBeam": {
				"width": (costs["ref_beam"] as Dictionary)["width"],
				"thickness": (costs["ref_beam"] as Dictionary)["thickness"],
				"length": (costs["ref_beam"] as Dictionary)["length_ft"],
				"price": (costs["ref_beam"] as Dictionary)["price"],
			},
		},
		"hardwareAssemblies": hardware_assemblies.duplicate(true),
		"visibility": {
			"brackets": show_brackets,
			"bolts": show_bolts,
			"hardwareFullDetail": show_hardware_full_detail,
			"solarPanels": sp["enabled"],
		},
		"cameraState": {"structureRotation": structure_rotation},
		"version": "v30",
	}


func _panel_section_to_config(sec: Dictionary) -> Dictionary:
	return {
		"enabled": sec["enabled"],
		"size": {
			"width": sec["panel_width"],
			"length": sec["panel_length"],
			"thickness": sec["panel_thickness"],
		},
		"electrical": {
			"ratedWatts": sec["rated_watts"],
			"voc": sec["voc"],
			"vmp": sec["vmp"],
			"isc": sec["isc"],
			"imp": sec["imp"],
			"weight": sec["weight"],
		},
		"padding": {"x": sec["padding_x"], "y": sec["padding_y"]},
		"grid": {"rows": sec["grid_rows"], "cols": sec["grid_cols"]},
		"lift": sec["panel_lift"],
	}


## Apply a config Dictionary (parsed JSON). Supports the v30 structured format
## and the legacy flat (v29) format used by older LinkageLab exports.
func from_config(cfg: Dictionary) -> void:
	if cfg.is_empty():
		return
	if cfg.has("structure"):
		_apply_v30(cfg)
	else:
		_apply_legacy_flat(cfg)


func _num(d: Dictionary, key: String, fallback: float) -> float:
	var v = d.get(key)
	if v is float or v is int:
		return float(v)
	return fallback


func _int(d: Dictionary, key: String, fallback: int) -> int:
	var v = d.get(key)
	if v is float or v is int:
		return int(v)
	return fallback


func _flag(d: Dictionary, key: String, fallback: bool) -> bool:
	var v = d.get(key)
	if v is bool:
		return v
	return fallback


func _apply_v30(cfg: Dictionary) -> void:
	var s: Dictionary = cfg.get("structure", {})
	modules = _int(s, "modules", modules)
	var bl: Dictionary = s.get("beamLengths", {})
	h_length_ft = _num(bl, "horizontal", h_length_ft)
	v_length_ft = _num(bl, "vertical", v_length_ft)
	pivot_pct = _num(s, "pivotPercent", pivot_pct)
	var sc: Dictionary = s.get("stackCounts", {})
	h_stack_count = _int(sc, "horizontal", h_stack_count)
	v_stack_count = _int(sc, "vertical", v_stack_count)
	var bd: Dictionary = s.get("beamDimensions", {})
	h_beam_w = _num(bd, "horizontalWidth", h_beam_w)
	h_beam_t = _num(bd, "horizontalThickness", h_beam_t)
	v_beam_w = _num(bd, "verticalWidth", v_beam_w)
	v_beam_t = _num(bd, "verticalThickness", v_beam_t)
	v_beam_inner_w = _num(bd, "verticalInnerWidth", v_beam_w)
	v_beam_inner_t = _num(bd, "verticalInnerThickness", v_beam_t)
	v_beam_outer_w = _num(bd, "verticalOuterWidth", v_beam_w)
	v_beam_outer_t = _num(bd, "verticalOuterThickness", v_beam_t)
	v_beam_dimensions_linked = _flag(bd, "verticalDimensionsLinked", v_beam_dimensions_linked)
	var offs: Dictionary = s.get("offsets", {})
	offset_top_in = _num(offs, "top", offset_top_in)
	offset_bot_in = _num(offs, "bottom", offset_bot_in)
	vert_end_offset = _num(offs, "vertEnd", vert_end_offset)
	h_stack_gap = _num(offs, "hStackGap", h_stack_gap)
	v_stack_gap = _num(offs, "vStackGap", v_stack_gap)
	var br: Dictionary = s.get("brackets", {})
	bracket_width = _num(br, "width", bracket_width)
	bracket_depth = _num(br, "depth", bracket_depth)
	bracket_height = _num(br, "height", bracket_height)
	bracket_wall_thickness = _num(br, "wallThickness", bracket_wall_thickness)
	bracket_inner_width = _num(br, "innerWidth", bracket_inner_width)
	bracket_hole_diameter = _num(br, "holeDiameter", bracket_hole_diameter)
	var brd: Dictionary = s.get("bracketDimensions", {})
	bracket_hole_distance = _num(brd, "holeDistance", bracket_hole_distance)
	var bo: Dictionary = s.get("bolts", {})
	bolt_diameter = _num(bo, "diameter", bolt_diameter)
	v_bolt_length = _num(bo, "vStackLength", v_bolt_length)
	h_bolt_length = _num(bo, "hStackLength", h_bolt_length)
	v_bolt_auto = _flag(bo, "vStackAuto", v_bolt_auto)
	h_bolt_auto = _flag(bo, "hStackAuto", h_bolt_auto)
	h_pivot_bolt_length = _num(bo, "hPivotBoltLength", h_pivot_bolt_length)
	h_pivot_bolt_auto = _flag(bo, "hPivotBoltAuto", h_pivot_bolt_auto)
	hoberman_ang = _num(s, "hobermanAngle", hoberman_ang)
	pivot_ang = _num(s, "pivotAngle", pivot_ang)
	v_stack_reverse = _flag(s, "vStackReverse", v_stack_reverse)
	_apply_washers_config(s.get("washers", {}))

	var mode: Dictionary = cfg.get("mode", {})
	orientation = "vertical" if str(mode.get("type", "")) == "arch" else "horizontal"
	arch_flip_vertical = _flag(mode, "flipVertical", arch_flip_vertical)
	arch_rotation = _num(mode, "rotation", arch_rotation)
	use_fixed_beams = _flag(mode, "useFixedBeams", use_fixed_beams)
	arch_cap_uprights = _flag(mode, "capUprights", arch_cap_uprights)
	array_count = _int(mode, "arrayCount", array_count)

	fold_angle = deg_to_rad(_num(cfg, "foldAngle", rad_to_deg(fold_angle)))
	animation_stop_angle = _num(cfg, "animationStopAngle", -1.0)
	min_fold_angle_deg = _num(cfg, "minFoldAngle", -1.0)
	radial_visible_angle = _num(cfg, "radialVisibleAngle", radial_visible_angle)
	rcp_visible_angle = _num(cfg, "rcpVisibleAngle", rcp_visible_angle)
	panels_visible_angle = _num(cfg, "panelsVisibleAngle", -1.0)

	var vis: Dictionary = cfg.get("visibility", {})
	show_brackets = _flag(vis, "brackets", show_brackets)
	show_bolts = _flag(vis, "bolts", show_bolts)
	show_hardware_full_detail = _flag(vis, "hardwareFullDetail", show_hardware_full_detail)

	var cam: Dictionary = cfg.get("cameraState", {})
	structure_rotation = _num(cam, "structureRotation", structure_rotation)

	_apply_support_beams_config(cfg.get("supportBeams", {}))
	_apply_panels_config(cfg.get("panels", {}), vis)
	_apply_costs_config(cfg.get("costs", {}))
	# `ensure` always deep-copies, so a config parsed off disk can be discarded.
	hardware_assemblies = LinkageHardware.ensure(cfg.get("hardwareAssemblies"))


func _apply_costs_config(cc: Dictionary) -> void:
	if cc.is_empty():
		return
	costs["h_beam"] = _num(cc, "hBeam", costs["h_beam"])
	costs["v_beam"] = _num(cc, "vBeam", costs["v_beam"])
	costs["bolt"] = _num(cc, "bolt", costs["bolt"])
	costs["bolt_v_inner"] = _num(cc, "boltVInner", costs["bolt_v_inner"])
	costs["bolt_v_outer"] = _num(cc, "boltVOuter", costs["bolt_v_outer"])
	costs["bolt_h"] = _num(cc, "boltH", costs["bolt_h"])
	costs["bolt_h_pivot"] = _num(cc, "boltHPivot", costs["bolt_h_pivot"])
	costs["washer_v"] = _num(cc, "washerV", costs["washer_v"])
	costs["washer_h"] = _num(cc, "washerH", costs["washer_h"])
	costs["bracket"] = _num(cc, "bracket", costs["bracket"])
	costs["solar_panel"] = _num(cc, "solarPanel", costs["solar_panel"])
	costs["auto_lumber"] = _flag(cc, "autoLumber", costs["auto_lumber"])
	var rb: Dictionary = cc.get("refBeam", {})
	if not rb.is_empty():
		var ref: Dictionary = costs["ref_beam"]
		ref["width"] = _num(rb, "width", ref["width"])
		ref["thickness"] = _num(rb, "thickness", ref["thickness"])
		ref["length_ft"] = _num(rb, "length", ref["length_ft"])
		ref["price"] = _num(rb, "price", ref["price"])


func _apply_washers_config(wc: Dictionary) -> void:
	if wc.is_empty():
		return
	washers["v_enabled"] = _flag(wc, "vEnabled", washers["v_enabled"])
	washers["v_id"] = _num(wc, "vID", washers["v_id"])
	washers["v_od"] = _num(wc, "vOD", washers["v_od"])
	washers["v_thickness"] = _num(wc, "vThickness", washers["v_thickness"])
	washers["v_auto"] = _flag(wc, "vAuto", washers["v_auto"])
	washers["h_enabled"] = _flag(wc, "hEnabled", washers["h_enabled"])
	washers["h_id"] = _num(wc, "hID", washers["h_id"])
	washers["h_od"] = _num(wc, "hOD", washers["h_od"])
	washers["h_thickness"] = _num(wc, "hThickness", washers["h_thickness"])
	washers["h_auto"] = _flag(wc, "hAuto", washers["h_auto"])


func _apply_support_beams_config(sbc: Dictionary) -> void:
	if sbc.is_empty():
		return
	var sb: Dictionary = support_beams
	sb["enabled"] = _flag(sbc, "enabled", sb["enabled"])
	sb["show_radial"] = _flag(sbc, "showRadial", sb.get("show_radial", true))
	sb["length"] = _num(sbc, "length", sb["length"])
	sb["width"] = _num(sbc, "width", sb["width"])
	sb["thickness"] = _num(sbc, "thickness", sb["thickness"])
	sb["rotation"] = _num(sbc, "rotation", sb["rotation"])
	sb["offset_h"] = _num(sbc, "offsetH", sb["offset_h"])
	sb["offset_v"] = _num(sbc, "offsetV", sb["offset_v"])
	sb["fold_angle"] = _num(sbc, "foldAngle", sb["fold_angle"])
	sb["parallel_enabled"] = _flag(sbc, "parallelEnabled", sb["parallel_enabled"])
	sb["parallel_length"] = _num(sbc, "parallelLength", sb["parallel_length"])
	sb["parallel_width"] = _num(sbc, "parallelWidth", sb["parallel_width"])
	sb["parallel_thickness"] = _num(sbc, "parallelThickness", sb["parallel_thickness"])
	sb["parallel_fold_angle"] = _num(sbc, "parallelFoldAngle", sb["parallel_fold_angle"])
	sb["parallel_swing_angle"] = _num(sbc, "parallelSwingAngle", sb["parallel_swing_angle"])
	sb["parallel_v_offset"] = _num(sbc, "parallelVOffset", sb["parallel_v_offset"])
	sb["parallel_offset_v"] = _num(sbc, "parallelOffsetV", sb["parallel_offset_v"])
	sb["anchor_dist"] = _num(sbc, "anchorDist", sb["anchor_dist"])
	sb["rcp_end_offset"] = _num(sbc, "rcpEndOffset", sb["rcp_end_offset"])


func _apply_panels_config(pc: Dictionary, vis: Dictionary) -> void:
	if pc.is_empty():
		return
	var sp: Dictionary = solar_panels
	sp["enabled"] = _flag(pc, "enabled", _flag(vis, "solarPanels", sp["enabled"]))
	_apply_panel_section(sp["top_panels"], pc.get("topPanels", {}))
	_apply_panel_section(sp["side_panels"], pc.get("sidePanels", {}))
	sp["layout_mode"] = str(pc.get("layoutMode", sp["layout_mode"]))
	sp["grid_rotation"] = _num(pc, "gridRotation", sp["grid_rotation"])
	var pos: Dictionary = pc.get("positioning", {})
	sp["arch_panel_offset"] = _num(pos, "lift", sp["arch_panel_offset"])
	sp["arch_panel_slide"] = _num(pos, "slide", sp["arch_panel_slide"])
	sp["arch_panel_separation"] = _num(pos, "separation", sp["arch_panel_separation"])
	var rad: Dictionary = pc.get("radial", {})
	sp["radial_count"] = _int(rad, "count", sp["radial_count"])
	sp["radial_offset"] = _num(rad, "offset", sp["radial_offset"])
	sp["radial_rotation"] = _num(rad, "rotation", sp["radial_rotation"])
	sp["radial_lateral_offset"] = _num(rad, "lateralOffset", sp["radial_lateral_offset"])
	sp["pinwheel_angle"] = _num(rad, "pinwheelAngle", sp["pinwheel_angle"])
	var spi: Dictionary = pc.get("spiral", {})
	sp["spiral_arm_count"] = _int(spi, "armCount", sp["spiral_arm_count"])
	sp["spiral_secondary_enabled"] = _flag(spi, "secondaryEnabled", sp["spiral_secondary_enabled"])
	sp["spiral_secondary_radial_offset"] = _num(spi, "secondaryRadialOffset", sp["spiral_secondary_radial_offset"])
	sp["spiral_secondary_lateral_offset"] = _num(spi, "secondaryLateralOffset", sp["spiral_secondary_lateral_offset"])
	sp["spiral_secondary_pinwheel"] = _num(spi, "secondaryPinwheel", sp["spiral_secondary_pinwheel"])
	sp["spiral_secondary_rotation"] = _num(spi, "secondaryRotation", sp["spiral_secondary_rotation"])
	sp["spiral_arm_radial_step"] = _num(spi, "armRadialStep", sp["spiral_arm_radial_step"])
	sp["spiral_arm_lateral_step"] = _num(spi, "armLateralStep", sp["spiral_arm_lateral_step"])
	sp["spiral_arm_pinwheel_step"] = _num(spi, "armPinwheelStep", sp["spiral_arm_pinwheel_step"])
	sp["spiral_arm_rotation_step"] = _num(spi, "armRotationStep", sp["spiral_arm_rotation_step"])
	var faces = pc.get("enabledFaces")
	sp["arch_wall_faces"] = faces if faces is Array else []


func _apply_panel_section(sec: Dictionary, pcs: Dictionary) -> void:
	if pcs.is_empty():
		return
	sec["enabled"] = _flag(pcs, "enabled", sec["enabled"])
	var size: Dictionary = pcs.get("size", {})
	sec["panel_width"] = _num(size, "width", sec["panel_width"])
	sec["panel_length"] = _num(size, "length", sec["panel_length"])
	sec["panel_thickness"] = _num(size, "thickness", sec["panel_thickness"])
	var el: Dictionary = pcs.get("electrical", {})
	sec["rated_watts"] = _num(el, "ratedWatts", sec["rated_watts"])
	sec["voc"] = _num(el, "voc", sec["voc"])
	sec["vmp"] = _num(el, "vmp", sec["vmp"])
	sec["isc"] = _num(el, "isc", sec["isc"])
	sec["imp"] = _num(el, "imp", sec["imp"])
	sec["weight"] = _num(el, "weight", sec["weight"])
	var pad: Dictionary = pcs.get("padding", {})
	sec["padding_x"] = _num(pad, "x", sec["padding_x"])
	sec["padding_y"] = _num(pad, "y", sec["padding_y"])
	var grid: Dictionary = pcs.get("grid", {})
	sec["grid_rows"] = _int(grid, "rows", sec["grid_rows"])
	sec["grid_cols"] = _int(grid, "cols", sec["grid_cols"])
	sec["panel_lift"] = _num(pcs, "lift", sec["panel_lift"])


## Legacy flat (v29-) config: keys match the web app state field names.
func _apply_legacy_flat(cfg: Dictionary) -> void:
	modules = _int(cfg, "modules", modules)
	h_length_ft = _num(cfg, "hLengthFt", h_length_ft)
	v_length_ft = _num(cfg, "vLengthFt", v_length_ft)
	pivot_pct = _num(cfg, "pivotPct", pivot_pct)
	hoberman_ang = _num(cfg, "hobermanAng", hoberman_ang)
	pivot_ang = _num(cfg, "pivotAng", pivot_ang)
	h_stack_count = _int(cfg, "hStackCount", h_stack_count)
	v_stack_count = _int(cfg, "vStackCount", v_stack_count)
	v_stack_reverse = _flag(cfg, "vStackReverse", v_stack_reverse)
	offset_top_in = _num(cfg, "offsetTopIn", offset_top_in)
	offset_bot_in = _num(cfg, "offsetBotIn", offset_bot_in)
	vert_end_offset = _num(cfg, "vertEndOffset", vert_end_offset)
	h_stack_gap = _num(cfg, "hStackGap", h_stack_gap)
	v_stack_gap = _num(cfg, "vStackGap", v_stack_gap)
	h_beam_w = _num(cfg, "hBeamW", h_beam_w)
	h_beam_t = _num(cfg, "hBeamT", h_beam_t)
	v_beam_w = _num(cfg, "vBeamW", v_beam_w)
	v_beam_t = _num(cfg, "vBeamT", v_beam_t)
	v_beam_inner_w = _num(cfg, "vBeamInnerW", v_beam_inner_w)
	v_beam_inner_t = _num(cfg, "vBeamInnerT", v_beam_inner_t)
	v_beam_outer_w = _num(cfg, "vBeamOuterW", v_beam_outer_w)
	v_beam_outer_t = _num(cfg, "vBeamOuterT", v_beam_outer_t)
	v_beam_dimensions_linked = _flag(cfg, "vBeamDimensionsLinked", v_beam_dimensions_linked)
	bracket_width = _num(cfg, "bracketWidth", bracket_width)
	bracket_depth = _num(cfg, "bracketDepth", bracket_depth)
	bracket_height = _num(cfg, "bracketHeight", bracket_height)
	bracket_wall_thickness = _num(cfg, "bracketWallThickness", bracket_wall_thickness)
	bracket_inner_width = _num(cfg, "bracketInnerWidth", bracket_inner_width)
	bracket_hole_diameter = _num(cfg, "bracketHoleDiameter", bracket_hole_diameter)
	bracket_hole_distance = _num(cfg, "bracketHoleDistance", bracket_hole_distance)
	bolt_diameter = _num(cfg, "boltDiameter", bolt_diameter)
	v_bolt_length = _num(cfg, "vBoltLength", v_bolt_length)
	h_bolt_length = _num(cfg, "hBoltLength", h_bolt_length)
	h_pivot_bolt_length = _num(cfg, "hPivotBoltLength", h_pivot_bolt_length)
	if cfg.has("foldAngle"):
		# Legacy stores radians directly in state dumps; heuristically accept
		# degrees when the value is clearly out of radian range.
		var fa := _num(cfg, "foldAngle", rad_to_deg(fold_angle))
		fold_angle = deg_to_rad(fa) if fa > TAU else fa
	orientation = str(cfg.get("orientation", orientation))
	arch_cap_uprights = _flag(cfg, "archCapUprights", arch_cap_uprights)
	use_fixed_beams = _flag(cfg, "useFixedBeams", use_fixed_beams)
	arch_flip_vertical = _flag(cfg, "archFlipVertical", arch_flip_vertical)
	arch_rotation = _num(cfg, "archRotation", arch_rotation)
	array_count = _int(cfg, "arrayCount", array_count)
	structure_rotation = _num(cfg, "structureRotation", structure_rotation)
	show_brackets = _flag(cfg, "showBrackets", show_brackets)
	show_bolts = _flag(cfg, "showBolts", show_bolts)
	show_hardware_full_detail = _flag(cfg, "showHardwareFullDetail", show_hardware_full_detail)
	if cfg.has("hardwareAssemblies"):
		hardware_assemblies = LinkageHardware.ensure(cfg.get("hardwareAssemblies"))

class_name FdmPrinterCaps
extends RefCounted

## Capability + UI defaults for any FDM printer (mud, trash, future).
## Built from graph-node specs so the shared Print Setup modal stays machine-
## agnostic: ranges, labels, presets, persist vs inventory, bed-lowering.

enum BedMotion { FIXED, LOWERING }

var model_id: String = ""
var machine_kind: String = ""
var display_name: String = "FDM Printer"
var bed_motion: int = BedMotion.FIXED
var print_persist: bool = false
var job_material_kind: String = ""
var default_print_mode: String = "solid"  # "solid" | "vase"
var show_design_building: bool = false
var show_part_presets: bool = false
var wet_label: String = "Wet color"
var dry_label: String = "Dry color"
var work_x_mm: float = 300.0
var work_y_mm: float = 300.0
var work_z_mm: float = 300.0
var nozzle_mm: float = 0.4
var line_width_mm: float = 0.4
var layer_height_mm: float = 0.2
var print_speed_mm_s: float = 60.0
## Slider ranges (mm / mm/s / unitless scale).
var nozzle_lo: float = 0.2
var nozzle_hi: float = 6.0
var wall_lo: float = 0.2
var wall_hi: float = 8.0
var layer_lo: float = 0.05
var layer_hi: float = 3.0
var speed_lo: float = 10.0
var speed_hi: float = 200.0
## One scale range for every printer (the slider is exponential): a model
## is whatever size its file is, so 4× was never a sensible ceiling — a
## 50 mm STL on a 3 m mud printer needs 40× (the old 8× cap clamped it).
var scale_lo: float = 0.001
var scale_hi: float = 1000.0
## Work (0, 0) is the bed's centre (a delta), not its front-left corner.
var origin_centred: bool = false
var wet_color: Color = Color(0.85, 0.55, 0.20)
var dry_color: Color = Color(0.35, 0.55, 0.65)
## Layer height as a fraction of nozzle when the nozzle slider changes.
var layer_from_nozzle_frac: float = 0.15


static func from_specs(specs: Dictionary) -> FdmPrinterCaps:
	var c := FdmPrinterCaps.new()
	var mid := str(specs.get("model_id", ""))
	var kind := str(specs.get("machine_kind", ""))
	if kind.is_empty():
		if mid == "trash_printer":
			kind = "trash"
		elif mid == "mud_printer":
			kind = "mud"
	c.model_id = mid
	c.machine_kind = kind
	c.display_name = str(specs.get("name", _default_name(kind, mid)))
	c.print_persist = bool(specs.get("print_persist", kind == "mud"))
	c.job_material_kind = str(specs.get("job_material_kind",
		"mud" if kind == "mud" else "plastic_flake"))
	c.work_x_mm = maxf(float(specs.get("work_x_mm", 300.0)), 50.0)
	c.work_y_mm = maxf(float(specs.get("work_y_mm", c.work_x_mm)), 50.0)
	c.work_z_mm = maxf(float(specs.get("work_z_mm", c.work_x_mm)), 50.0)

	# Bed motion: explicit flag, else mud = fixed, trash / invert-Z bed = lowering.
	if specs.has("bed_lowering"):
		c.bed_motion = BedMotion.LOWERING if bool(specs.get("bed_lowering")) \
			else BedMotion.FIXED
	elif kind == "mud" or mid == "mud_printer":
		c.bed_motion = BedMotion.FIXED
	elif kind == "trash" or mid == "trash_printer":
		c.bed_motion = BedMotion.LOWERING
	else:
		c.bed_motion = BedMotion.FIXED

	if kind == "mud" or mid == "mud_printer":
		c._apply_mud_defaults(specs)
	elif kind == "trash" or mid == "trash_printer":
		c._apply_trash_defaults(specs)
	else:
		c._apply_generic_fdm_defaults(specs)

	# Spec overrides always win for the live dial-in values.
	c.nozzle_mm = maxf(float(specs.get("filament_diameter_mm",
		specs.get("nozzle_diameter_mm", c.nozzle_mm))), c.nozzle_lo)
	c.line_width_mm = maxf(float(specs.get("line_width_mm", c.nozzle_mm)), c.wall_lo)
	c.layer_height_mm = maxf(float(specs.get("layer_height_mm", c.layer_height_mm)), c.layer_lo)
	c.print_speed_mm_s = maxf(float(specs.get("print_speed_mm_s", c.print_speed_mm_s)), c.speed_lo)
	c._fit_ranges()
	var gspec: Variant = specs.get("gantry_spec", {})
	if gspec is Dictionary and str((gspec as Dictionary).get("kinematics", "")) == "delta":
		c.origin_centred = true
	if specs.has("print_mode"):
		c.default_print_mode = str(specs.get("print_mode"))
	c.wet_color = _color_from(specs.get("wet_color"), c.wet_color)
	c.dry_color = _color_from(specs.get("dry_color"), c.dry_color)
	return c


## Slider ranges that hold this printer's own head: a designed gantry with
## the 6 mm flake extruder is "generic FDM" by kind, and its 0.2–2.5 mm line
## range clamped a 6 mm road to 2.5 mm — the same STL sliced at a third of
## the Trash Printer's road width on the same head.
func _fit_ranges() -> void:
	nozzle_hi = maxf(nozzle_hi, nozzle_mm * 1.5)
	nozzle_lo = minf(nozzle_lo, nozzle_mm)
	wall_hi = maxf(wall_hi, maxf(line_width_mm, nozzle_mm) * 1.6)
	wall_lo = minf(wall_lo, line_width_mm)
	layer_hi = maxf(layer_hi, maxf(layer_height_mm * 1.5, nozzle_mm * 0.75))
	layer_lo = minf(layer_lo, layer_height_mm)
	if nozzle_mm > 2.0 and layer_from_nozzle_frac >= 0.5 and machine_kind != "mud":
		# A big plastic nozzle prints layers far thinner than half its bore.
		layer_from_nozzle_frac = clampf(layer_height_mm / nozzle_mm, 0.1, 0.5)
	speed_hi = maxf(speed_hi, print_speed_mm_s * 2.0)


## The bed point (work mm) the footprint is centred on before the offsets.
func bed_centre_mm() -> Vector2:
	return Vector2.ZERO if origin_centred else Vector2(work_x_mm * 0.5, work_y_mm * 0.5)


## Work bounds of the bed (mm): [min, max] corners in X / Y.
func bed_rect_mm() -> Rect2:
	var c := bed_centre_mm()
	return Rect2(c - Vector2(work_x_mm, work_y_mm) * 0.5, Vector2(work_x_mm, work_y_mm))


func work_m() -> float:
	return maxf(work_x_mm / 1000.0, 0.05)


func is_bed_lowering() -> bool:
	return bed_motion == BedMotion.LOWERING


func suggested_layer_for_nozzle(nozzle: float) -> float:
	return clampf(nozzle * layer_from_nozzle_frac, layer_lo, layer_hi)


func part_presets() -> Array:
	if not show_part_presets:
		return []
	if machine_kind == "trash" or model_id == "trash_printer":
		return DomeParts.print_presets()
	return []


func _apply_mud_defaults(specs: Dictionary) -> void:
	display_name = str(specs.get("name", "Mud Printer"))
	show_design_building = true
	show_part_presets = false
	print_persist = true
	default_print_mode = "vase"
	wet_label = "Wet color"
	dry_label = "Dry color"
	nozzle_mm = 76.2
	line_width_mm = 76.2
	layer_height_mm = 50.0
	print_speed_mm_s = 120.0
	layer_from_nozzle_frac = 0.5
	nozzle_lo = 3.0
	nozzle_hi = 150.0
	wall_lo = 1.0
	wall_hi = 200.0
	layer_lo = 0.5
	layer_hi = 100.0
	speed_lo = 10.0
	speed_hi = 600.0
	wet_color = Color(0.36, 0.26, 0.17)
	dry_color = Color(0.68, 0.56, 0.42)
	if work_x_mm < 1000.0:
		work_x_mm = 3048.0
		work_y_mm = 3048.0
		work_z_mm = 3048.0


func _apply_trash_defaults(specs: Dictionary) -> void:
	display_name = str(specs.get("name", "Trash Printer"))
	show_design_building = false
	show_part_presets = true
	print_persist = false
	default_print_mode = "solid"
	wet_label = "Filament color"
	dry_label = "Finished color"
	# 6 mm flake nozzle; layer height in the practical 0.3–1.5 mm band.
	nozzle_mm = 6.0
	line_width_mm = 6.0
	layer_height_mm = 0.8
	print_speed_mm_s = 40.0
	layer_from_nozzle_frac = 0.13  # 6×0.13 ≈ 0.78 mm
	nozzle_lo = 2.0
	nozzle_hi = 8.0
	wall_lo = 2.0
	wall_hi = 10.0
	layer_lo = 0.3
	layer_hi = 1.5
	speed_lo = 5.0
	speed_hi = 120.0
	wet_color = Color(0.85, 0.55, 0.20)
	dry_color = Color(0.35, 0.55, 0.65)
	if work_x_mm < 100.0:
		work_x_mm = 600.0
		work_y_mm = 600.0
		work_z_mm = 600.0


func _apply_generic_fdm_defaults(specs: Dictionary) -> void:
	display_name = str(specs.get("name", "FDM Printer"))
	show_design_building = false
	show_part_presets = false
	default_print_mode = "solid"
	wet_label = "Filament color"
	dry_label = "Finished color"
	nozzle_mm = 0.4
	line_width_mm = 0.45
	layer_height_mm = 0.2
	print_speed_mm_s = 60.0
	layer_from_nozzle_frac = 0.5
	nozzle_lo = 0.2
	nozzle_hi = 2.0
	wall_lo = 0.2
	wall_hi = 2.5
	layer_lo = 0.05
	layer_hi = 0.6
	speed_lo = 10.0
	speed_hi = 200.0


static func _default_name(kind: String, mid: String) -> String:
	if kind == "mud" or mid == "mud_printer":
		return "Mud Printer"
	if kind == "trash" or mid == "trash_printer":
		return "Trash Printer"
	return "FDM Printer"


static func _color_from(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback

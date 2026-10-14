class_name GraphSoilLegend
extends PanelContainer

## Soil key for the graph's Elevation and Globe lenses: one swatch per horizon
## of the cutaway's Pacific-Northwest soil profile (soi_strata.gdshaderinc),
## the depth each is drawn at, the water table, and the percolation channels.
## The header collapses it to one line.
##
## COLORS mirrors the shader's horizon constants in sRGB (the comments next to
## SOI_C_* there) — edit both. Depths mirror soi_soil_profile's boundaries
## (base × k, k = clamp(R / 45, 1, 5)): horizons are drawn deeper than real
## soil so a 1 m humus layer still reads on a 300 m globe, and the key says so.

const COLORS := {
	"litter": Color8(0x38, 0x26, 0x19),
	"topsoil": Color8(0x54, 0x38, 0x24),
	"subsoil": Color8(0x96, 0x5a, 0x3c),
	"till": Color8(0x8c, 0x66, 0x47),
	"basalt": Color8(0x3d, 0x3b, 0x3b),
	"water": Color8(0x1a, 0x47, 0x73),
	"channel": Color8(0x73, 0xc7, 0xff),
}
## Horizon boundaries in units of k (soi_soil_profile: b_o, b_a, b_b, b_bc).
const BOUNDS_K := [0.6, 2.6, 8.0, 17.0]
## Water table depth below the SoI centre, as a fraction of R (soi_water_level).
const WATER_FRAC := 0.70

var _collapsed := false
var _header: Button = null
var _body: VBoxContainer = null
var _rows: Dictionary = {}
var _note: Label = null
var _last_r := -1.0


static func horizon_k(r: float) -> float:
	return clampf(r / 45.0, 1.0, 5.0)


const NAMES := {
	"litter": "Litter & humus",
	"topsoil": "Topsoil",
	"subsoil": "Iron-rich subsoil",
	"till": "Glacial till",
	"basalt": "Columnar basalt",
	"water": "Groundwater",
}


## Which horizon a point at world height `y` sits in, under ground at
## `ground_y`, in an SoI of radius `r` centred at height `center_y` — the
## shader's boundaries without their undulation (good to the band, which is
## what a hover readout needs). "" above ground.
static func horizon_at(y: float, ground_y: float, r: float, center_y: float) -> String:
	var d := ground_y - y
	if d < 0.0:
		return ""
	if y < center_y - r * WATER_FRAC:
		return "water"
	var bottom := center_y - r
	var tn := d / maxf(ground_y - bottom, 1.0)
	if tn > 0.46:
		return "basalt"
	var k := horizon_k(r)
	if d < float(BOUNDS_K[0]) * k:
		return "litter"
	if d < float(BOUNDS_K[1]) * k:
		return "topsoil"
	if d < float(BOUNDS_K[2]) * k:
		return "subsoil"
	return "till"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_BG, 0.78)
	sb.border_color = Color(UITheme.C_BORDER, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 8.0
	add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	add_child(col)
	_header = Button.new()
	_header.flat = true
	_header.focus_mode = Control.FOCUS_NONE
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_header.add_theme_color_override("font_color", UITheme.C_TEXT)
	_header.add_theme_color_override("font_hover_color", UITheme.C_PRIMARY)
	_header.tooltip_text = "Soil profile of the cutaway — click to collapse"
	_header.pressed.connect(_toggle)
	col.add_child(_header)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 3)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_body)
	for key in ["litter", "topsoil", "subsoil", "till", "basalt", "water", "channel"]:
		_rows[key] = _make_row(key)
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_note)
	_sync_header()


func _make_row(key: String) -> Label:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	var sw := ColorRect.new()
	sw.color = COLORS[key]
	sw.custom_minimum_size = Vector2(14, 10) if key != "channel" else Vector2(14, 4)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(sw)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)
	_body.add_child(row)
	return lbl


## Refresh the depth figures for an SoI of radius `r` (metres).
func set_radius(r: float) -> void:
	if is_equal_approx(r, _last_r):
		return
	_last_r = r
	var k := horizon_k(r)
	var b: Array = []
	for v in BOUNDS_K:
		b.append(float(v) * k)
	(_rows["litter"] as Label).text = "Litter & humus  0–%s" % _m(b[0])
	(_rows["topsoil"] as Label).text = "Topsoil  %s–%s" % [_m(b[0]), _m(b[1])]
	(_rows["subsoil"] as Label).text = "Iron-rich subsoil  %s–%s" % [_m(b[1]), _m(b[2])]
	(_rows["till"] as Label).text = "Glacial till & cobbles  %s–%s" % [_m(b[2]), _m(b[3])]
	(_rows["basalt"] as Label).text = "Columnar basalt  from ~%s" % _m(r * 0.46)
	(_rows["water"] as Label).text = "Water table  −%s below the centre" % _m(r * WATER_FRAC)
	(_rows["channel"] as Label).text = "Percolation channels (flowing)"
	_note.text = "depths drawn ×%.1f for legibility" % k if k > 1.01 else "true-scale depths"


static func _m(v: float) -> String:
	return ("%.1f m" % v) if v < 10.0 else ("%.0f m" % v)


func _toggle() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_sync_header()
	reset_size()


func _sync_header() -> void:
	if _header != null:
		_header.text = ("Soil profile  ▸" if _collapsed else "Soil profile  ▾")

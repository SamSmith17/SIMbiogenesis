class_name CarpetPlot
extends Control

## A carpet plot (plans/FLOW_VIZ_PLAN.md Part D): one cell per hour, a column
## per day, hours of the day running down, so seasons read across and the
## daily rhythm reads down at once. Colour is ONE hue ramp (dark near zero,
## light at the top) or, for a value with a sign, a diverging pair round a
## grey "nothing". The image is built when the data is set, never inside
## _draw (a GPU resource made mid-draw has undefined contents).
##
##   set_data(values, days, {ramp: "power"|"sun"|"water"|"diverging",
##            fmt: Callable(v) -> String, day_label: Callable(day) -> String,
##            ticks: [[day, "Mar"], …], range: Vector2 (else the data's)})

const PAD_L := 34.0
const PAD_B := 20.0
const PAD_R := 82.0
const PAD_T := 6.0
## Single-hue ramps on the dark surface: near zero recedes into it.
const RAMPS := {
	"power": [Color("#2a1d06"), Color("#7a4f0c"), Color("#d99a1c"), Color("#ffe3a3")],
	"sun": [Color("#2a1d06"), Color("#7a4f0c"), Color("#d99a1c"), Color("#ffe3a3")],
	"charge": [Color("#0d2340"), Color("#184f95"), Color("#3987e5"), Color("#cde2fb")],
	"water": [Color("#082a33"), Color("#0e5f73"), Color("#25a8c6"), Color("#bff0fb")],
}
const DIV_NEG := Color("#d03b3b")
const DIV_MID := Color("#383835")
const DIV_POS := Color("#3987e5")
const C_EMPTY := Color(0.12, 0.14, 0.19, 1.0)

var values := PackedFloat32Array()
var days := 0
var opts: Dictionary = {}
var _tex: ImageTexture = null
var _range := Vector2(0.0, 1.0)
var _hover := Vector2i(-1, -1)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size.y = maxf(custom_minimum_size.y, 170.0)
	mouse_exited.connect(func() -> void:
		_hover = Vector2i(-1, -1)
		queue_redraw())


func set_data(v: PackedFloat32Array, n_days: int, o: Dictionary = {}) -> void:
	values = v
	days = maxi(n_days, 0)
	opts = o
	var r: Vector2 = o.get("range", PatternData.finite_range(v))
	if is_nan(r.x):
		r = Vector2(0.0, 1.0)
	if is_diverging():
		var m := maxf(absf(r.x), absf(r.y))
		r = Vector2(-m, m)
	if r.y - r.x < 1e-9:
		r.y = r.x + 1.0
	_range = r
	_build_texture()
	queue_redraw()


func is_diverging() -> bool:
	return str(opts.get("ramp", "power")) == "diverging"


## The colour of a value (NAN = no data).
func color_of(v: float) -> Color:
	if is_nan(v):
		return C_EMPTY
	var t := clampf((v - _range.x) / (_range.y - _range.x), 0.0, 1.0)
	if is_diverging():
		return DIV_NEG.lerp(DIV_MID, t * 2.0) if t < 0.5 else DIV_MID.lerp(DIV_POS, (t - 0.5) * 2.0)
	var ramp: Array = RAMPS.get(str(opts.get("ramp", "power")), RAMPS["power"])
	var f := t * float(ramp.size() - 1)
	var i := mini(int(floor(f)), ramp.size() - 2)
	return (ramp[i] as Color).lerp(ramp[i + 1] as Color, f - float(i))


func _build_texture() -> void:
	if days <= 0:
		_tex = null
		return
	var img := Image.create(days, 24, false, Image.FORMAT_RGBA8)
	for d in days:
		for h in 24:
			var i := d * 24 + h
			img.set_pixel(d, h, color_of(float(values[i]) if i < values.size() else NAN))
	if _tex == null or _tex.get_width() != days:
		_tex = ImageTexture.create_from_image(img)
	else:
		_tex.update(img)


func _plot_rect() -> Rect2:
	return Rect2(Vector2(PAD_L, PAD_T), Vector2(maxf(size.x - PAD_L - PAD_R, 10.0),
		maxf(size.y - PAD_T - PAD_B, 10.0)))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var r := _plot_rect()
		var p := (event as InputEventMouseMotion).position
		var h := Vector2i(-1, -1)
		if r.has_point(p) and days > 0:
			h = Vector2i(clampi(int((p.x - r.position.x) / r.size.x * float(days)), 0, days - 1),
				clampi(int((p.y - r.position.y) / r.size.y * 24.0), 0, 23))
		if h != _hover:
			_hover = h
			queue_redraw()


func _draw() -> void:
	var font := UITheme.font("regular", true)
	var r := _plot_rect()
	if _tex == null:
		draw_string(font, r.position + Vector2(8, 20), "No days recorded yet.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM, UITheme.C_TEXT_M)
		return
	# Nearest filter: cells stay crisp at any size.
	draw_texture_rect(_tex, r, false)
	# Hours down the left: midnight, 6, noon, 18.
	for hh in [0, 6, 12, 18]:
		var y := r.position.y + r.size.y * float(hh) / 24.0
		draw_string(font, Vector2(2.0, y + 9.0), "%02d" % hh, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, UITheme.C_TEXT_M)
	# Days along the bottom.
	var ticks: Array = opts.get("ticks", [])
	var last_x := -1e9
	for t in ticks:
		var x := r.position.x + r.size.x * (float(t[0]) + 0.5) / float(days)
		var tw := font.get_string_size(str(t[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_XS).x
		if x - last_x < tw + 10.0:
			continue
		last_x = x
		draw_line(Vector2(x, r.end.y), Vector2(x, r.end.y + 3.0), UITheme.C_TEXT_M, 1.0)
		draw_string(font, Vector2(x - tw * 0.5, r.end.y + 15.0), str(t[1]), HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_XS, UITheme.C_TEXT_M)
	# Colour key on the right: the ramp with its two ends labelled.
	var kx := r.end.x + 10.0
	var kh := r.size.y
	var n := 24
	for k in n:
		var v := lerpf(_range.y, _range.x, float(k) / float(n - 1))
		draw_rect(Rect2(kx, r.position.y + kh * float(k) / float(n), 10.0, kh / float(n) + 0.5), color_of(v))
	var fmt: Callable = opts.get("fmt", Callable())
	var hi_t: String = str(fmt.call(_range.y)) if fmt.is_valid() else "%.3g" % _range.y
	var lo_t: String = str(fmt.call(_range.x)) if fmt.is_valid() else "%.3g" % _range.x
	draw_string(font, Vector2(kx + 13.0, r.position.y + 9.0), hi_t, HORIZONTAL_ALIGNMENT_LEFT, PAD_R - 24.0,
		UITheme.FONT_XS, UITheme.C_TEXT_S)
	draw_string(font, Vector2(kx + 13.0, r.end.y), lo_t, HORIZONTAL_ALIGNMENT_LEFT, PAD_R - 24.0,
		UITheme.FONT_XS, UITheme.C_TEXT_S)
	# Hover: outline the cell and say what it holds.
	if _hover.x >= 0:
		var cw := r.size.x / float(days)
		var ch := r.size.y / 24.0
		var cell := Rect2(r.position + Vector2(float(_hover.x) * cw, float(_hover.y) * ch), Vector2(cw, ch))
		draw_rect(cell.grow(1.0), UITheme.C_TEXT, false, 1.5)
		var i := _hover.x * 24 + _hover.y
		var v := float(values[i]) if i < values.size() else NAN
		var dl: Callable = opts.get("day_label", Callable())
		var when := "%s, %02d:00" % [str(dl.call(_hover.x)) if dl.is_valid() else "day %d" % (_hover.x + 1), _hover.y]
		var what := "no data" if is_nan(v) else (str(fmt.call(v)) if fmt.is_valid() else "%.3g" % v)
		var txt := "%s · %s" % [when, what]
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM).x + 12.0
		var bx := clampf(cell.position.x + cw + 6.0, 0.0, size.x - tw)
		var by := clampf(cell.position.y - 22.0, 0.0, size.y - 20.0)
		draw_rect(Rect2(bx, by, tw, 20.0), Color(UITheme.C_BG, 0.94))
		draw_rect(Rect2(bx, by, tw, 20.0), UITheme.C_BORDER, false, 1.0)
		draw_string(font, Vector2(bx + 6.0, by + 14.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FONT_SM, UITheme.C_TEXT)

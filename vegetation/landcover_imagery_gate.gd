class_name LandcoverImageryGate
extends RefCounted

## Phase 2 placement gate: wraps the satellite drape as a vegetation allow-mask +
## coarse canopy-height proxy, reusing the dark-green canopy classifier from
## vegetation_scatter.gd (_is_vegetation_color). It fills the gaps OSM polygons
## miss — e.g. a player spawning in a clearing whose surrounding tree cover isn't
## tagged in OSM. The drape is cropped to the bbox, so world (x,z) in metres maps
## linearly onto UV 0..1 across the drape's `extent_m` square.
##
## Stand-in for true ESA WorldCover (Phase 4): "dark + green + chroma" approximates
## WorldCover class 10 (tree cover). Canopy reads brighter/olive in arid imagery,
## so this is intentionally tuned for temperate dark canopy and is the rollback
## floor once the real land-cover raster lands.

const LUMA_THRESHOLD := 0.30
const GREEN_EXCESS := 0.01
const MIN_CHROMA := 0.04

var _img: Image = null
var _w := 0
var _h := 0
var _extent := 0.0   # world metres spanned by the (square) drape
var _half := 0.0
var _detail_img: Image = null
var _detail_w := 0
var _detail_h := 0
var _detail_extent := 0.0
var _detail_half := 0.0


static func from_texture(tex: Texture2D, extent_m: float,
		detail_tex: Texture2D = null, detail_extent_m: float = 0.0) -> LandcoverImageryGate:
	if tex == null or extent_m <= 0.0:
		return null
	var img := _texture_to_image(tex)
	if img == null:
		return null
	var g := LandcoverImageryGate.new()
	g._img = img
	g._w = img.get_width()
	g._h = img.get_height()
	g._extent = extent_m
	g._half = extent_m * 0.5
	if detail_tex != null and detail_extent_m > 0.0:
		var dimg := _texture_to_image(detail_tex)
		if dimg != null:
			g._detail_img = dimg
			g._detail_w = dimg.get_width()
			g._detail_h = dimg.get_height()
			g._detail_extent = detail_extent_m
			g._detail_half = detail_extent_m * 0.5
	return g


## Lighter gate for scatter/gap-fill: downsampled CPU images (scatter only).
static func from_texture_downsampled(tex: Texture2D, extent_m: float, max_px: int = 512,
		detail_tex: Texture2D = null, detail_extent_m: float = 0.0,
		detail_max_px: int = 512) -> LandcoverImageryGate:
	if tex == null or extent_m <= 0.0:
		return null
	var img := _downsample_texture(tex, max_px)
	if img == null:
		return null
	var g := LandcoverImageryGate.new()
	g._img = img
	g._w = img.get_width()
	g._h = img.get_height()
	g._extent = extent_m
	g._half = extent_m * 0.5
	if detail_tex != null and detail_extent_m > 0.0:
		var dimg := _downsample_texture(detail_tex, detail_max_px)
		if dimg != null:
			g._detail_img = dimg
			g._detail_w = dimg.get_width()
			g._detail_h = dimg.get_height()
			g._detail_extent = detail_extent_m
			g._detail_half = detail_extent_m * 0.5
	return g


static func _downsample_texture(tex: Texture2D, max_px: int) -> Image:
	var img := _texture_to_image(tex)
	if img == null:
		return null
	var w := img.get_width()
	var h := img.get_height()
	var longest := maxi(w, h)
	if longest > max_px:
		var scale := float(max_px) / float(longest)
		img.resize(maxi(1, int(round(float(w) * scale))), maxi(1, int(round(float(h) * scale))))
	return img


static func _texture_to_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		if img.decompress() != OK:
			return null
	return img


func is_valid() -> bool:
	return _img != null and _w > 0 and _h > 0


## World (x,z) metres → drape pixel colour; transparent black when out of bounds.
## Inside the optional hi-res detail square, samples the detail patch when present.
func sample(x: float, z: float) -> Color:
	if _detail_img != null and _detail_extent > 0.0:
		if absf(x) <= _detail_half and absf(z) <= _detail_half:
			var du := (x + _detail_half) / _detail_extent
			var dv := (z + _detail_half) / _detail_extent
			if du >= 0.0 and du < 1.0 and dv >= 0.0 and dv < 1.0:
				var dpx := clampi(int(du * float(_detail_w)), 0, _detail_w - 1)
				var dpy := clampi(int(dv * float(_detail_h)), 0, _detail_h - 1)
				return _detail_img.get_pixel(dpx, dpy)
	var u := (x + _half) / _extent
	var v := (z + _half) / _extent
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var px := clampi(int(u * float(_w)), 0, _w - 1)
	var py := clampi(int(v * float(_h)), 0, _h - 1)
	return _img.get_pixel(px, py)


func is_vegetated(x: float, z: float) -> bool:
	var c := sample(x, z)
	if c.a <= 0.0:
		return false
	return is_vegetation_color(c)


## 0 (sparse/edge) … 1 (darkest canopy) — a coarse height/density proxy.
func canopy_factor(x: float, z: float) -> float:
	var c := sample(x, z)
	if c.a <= 0.0:
		return 0.0
	var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	return clampf((LUMA_THRESHOLD - luma) / LUMA_THRESHOLD, 0.0, 1.0)


## Vegetated green tint from drape pixel — for foliage color matching.
func foliage_tint(x: float, z: float) -> Color:
	var c := sample(x, z)
	if c.a <= 0.0 or not is_vegetation_color(c):
		return Color(0.12, 0.28, 0.08)
	return Color(c.r, c.g, c.b, 1.0)


## Mean foliage tint over a polygon (coarse grid sample).
func mean_foliage_tint(poly: PackedVector2Array, samples: int = 8) -> Color:
	if poly.is_empty() or not is_valid():
		return Color(0.12, 0.28, 0.08)
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for iz in samples:
		for ix in samples:
			var fx := float(ix) / float(maxi(samples - 1, 1))
			var fz := float(iz) / float(maxi(samples - 1, 1))
			var pt := Vector2(lerpf(min_x, max_x, fx), lerpf(min_z, max_z, fz))
			if Geometry2D.is_point_in_polygon(pt, poly):
				var t := foliage_tint(pt.x, pt.y)
				acc += t
				n += 1
	if n == 0:
		return Color(0.12, 0.28, 0.08)
	acc /= float(n)
	return Color(acc.r, acc.g, acc.b, 1.0)


## Site-wide mean dark-green haze color from a coarse grid sample.
func compute_haze_color(grid_n: int = 32) -> Color:
	if not is_valid():
		return Color(0.07, 0.13, 0.04)
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for iz in grid_n:
		for ix in grid_n:
			var u := (float(ix) + 0.5) / float(grid_n)
			var v := (float(iz) + 0.5) / float(grid_n)
			var x := u * _extent - _half
			var z := v * _extent - _half
			var c := sample(x, z)
			if is_vegetation_color(c):
				acc += c
				n += 1
	if n == 0:
		return Color(0.07, 0.13, 0.04)
	acc /= float(n)
	return Color(acc.r * 0.85, acc.g * 0.85, acc.b * 0.85, 1.0)


## Ported verbatim from VegetationScatter._is_vegetation_color (default thresholds).
static func is_vegetation_color(c: Color) -> bool:
	var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	if luma > LUMA_THRESHOLD:
		return false
	if c.g - maxf(c.r, c.b) < GREEN_EXCESS:
		return false
	var chroma := maxf(maxf(c.r, c.g), c.b) - minf(minf(c.r, c.g), c.b)
	return chroma >= MIN_CHROMA

class_name ParametricMaterialSynth
extends RefCounted

## Procedural PBR texture synthesizer + image normalizer for `ParametricMaterialLibrary`.
##
## Produces compact, seamless, mipmapped PBR map sets (`albedo`, `normal`,
## `roughness`, `ao`) per material pattern on demand and caches them globally:
##   - Directional wood grain & rotary-peeled plywood veneer
##   - Brushed metal streaks (aluminum, stainless, copper, brass)
##   - Powder-coat micro-orange-peel
##   - Hot-dip galvanized crystalline Voronoi spangle
##   - Corrugated metal roofing sinusoidal ribs + valley AO
##   - Corten weathering steel oxide crust & rust pits
##   - Basket-weave technical fabric / canvas
##   - Spark-eroded molded polymer stipple (HDPE / ABS / PVC / EPDM)
##   - Porous mineral aggregate (concrete / rammed earth / mud)
##   - Solar PV silicon cell micro-grid & subtle rolled glass waviness
##
## Also normalizes full-color CC0 or user-uploaded photos into tint-neutral
## luminance grain maps (so part colors tint cleanly without color muddiness)
## and derives tangent-space OpenGL normal + roughness maps when a user uploads
## only a single color image.

const MAP_SIZE := 128

static var _proc_cache: Dictionary = {}
static var _grain_cache: Dictionary = {}
static var _derived_cache: Dictionary = {}


static func clear_caches() -> void:
	_proc_cache.clear()
	_grain_cache.clear()
	_derived_cache.clear()


## Return cached `{albedo: Texture2D, normal: Texture2D, roughness: Texture2D, ao: Texture2D}`
## for `pattern`, modulated by `grain_strength` (`0..1`) and `rough_contrast` (`0..1`).
static func procedural_maps(pattern: String, grain_strength: float = 0.5, rough_contrast: float = 0.5) -> Dictionary:
	var gs := snappedf(clampf(grain_strength, 0.0, 1.0), 0.05)
	var rc := snappedf(clampf(rough_contrast, 0.0, 1.0), 0.05)
	var key := "%s|%.2f|%.2f" % [pattern, gs, rc]
	if _proc_cache.has(key):
		return _proc_cache[key]

	var sz := MAP_SIZE
	var h_field := PackedFloat32Array()
	var r_field := PackedFloat32Array()
	var g_field := PackedFloat32Array()
	var ao_field := PackedFloat32Array()
	h_field.resize(sz * sz)
	r_field.resize(sz * sz)
	g_field.resize(sz * sz)
	ao_field.resize(sz * sz)
	ao_field.fill(1.0)

	var n_main := _make_noise(hash(pattern + "_m"), FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0, 3)
	var n_fine := _make_noise(hash(pattern + "_f"), FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 3.0, 2)
	var n_cell := _make_cellular(hash(pattern + "_c"), 1.0)

	var bump_amp := 1.0
	for y in sz:
		var v := float(y) / float(sz)
		for x in sz:
			var u := float(x) / float(sz)
			var idx := y * sz + x
			var h := 0.5
			var r := 0.5
			var g := 0.5
			var ao := 1.0

			match pattern:
				"wood_grain":
					# Elongated fibers along V + subtle growth-ring wave across U.
					var warp := _tile_noise(n_main, u * 2.0, v * 0.5, 2.0, 0.5) * 0.35
					var rings := 0.5 + 0.5 * sin((u * 5.0 + warp) * TAU)
					var fiber := _tile_noise(n_fine, u * 10.0, v * 1.5, 10.0, 1.5)
					h = rings * 0.55 + fiber * 0.45
					g = rings * 0.65 + fiber * 0.35
					r = 1.0 - (rings * 0.6 + fiber * 0.4) # late-wood rings slightly smoother
					bump_amp = 1.35
				"plywood_veneer":
					# Wide rotary-cut cathedral swirls + fine wood pores.
					var swirl := _tile_noise(n_main, u * 1.5, v * 0.75, 1.5, 0.75)
					var cathedral := 0.5 + 0.5 * sin((swirl * 3.2 + u * 2.0) * TAU * 0.5)
					var pores := _tile_noise(n_fine, u * 8.0, v * 2.0, 8.0, 2.0)
					h = cathedral * 0.45 + pores * 0.55
					g = cathedral * 0.70 + pores * 0.30
					r = 1.0 - cathedral * 0.45 + (pores - 0.5) * 0.35
					bump_amp = 1.25
				"brushed_metal":
					# Directional hairline streaks along U + faint roll banding.
					var streak := _tile_noise(n_fine, u * 1.0, v * 14.0, 1.0, 14.0)
					var band := _tile_noise(n_main, u * 1.0, v * 3.0, 1.0, 3.0)
					h = streak * 0.75 + band * 0.25
					g = 0.42 + streak * 0.16
					r = 0.35 + streak * 0.50 + band * 0.15
					bump_amp = 0.90
				"powder_coat":
					# Isotropic fine orange-peel micro-facets.
					var peel := _tile_noise(n_main, u * 5.0, v * 5.0, 5.0, 5.0)
					var micro := _tile_noise(n_fine, u * 11.0, v * 11.0, 11.0, 11.0)
					h = peel * 0.70 + micro * 0.30
					g = 0.48 + peel * 0.04
					r = 0.42 + micro * 0.36 + peel * 0.22
					bump_amp = 0.95
				"galvanized_spangle":
					# Crystalline zinc spangle Voronoi facets with distinct sheen per crystal.
					var cell_v := _tile_noise(n_cell, u * 4.0, v * 4.0, 4.0, 4.0)
					var fine := _tile_noise(n_fine, u * 9.0, v * 9.0, 9.0, 9.0)
					var quant := floorf(cell_v * 6.0) / 6.0
					h = quant * 0.45 + fine * 0.55
					g = 0.30 + quant * 0.50 + fine * 0.20
					r = 0.20 + (1.0 - quant) * 0.65 + (fine - 0.5) * 0.15
					bump_amp = 0.85
				"corrugated_metal":
					# 6 sinusoidal roofing/siding ribs per tile + sheet micro-grain + valley AO.
					var phase := u * 6.0 * TAU
					var rib := 0.5 + 0.5 * cos(phase)
					var micro2 := _tile_noise(n_fine, u * 6.0, v * 6.0, 6.0, 6.0)
					h = rib * 0.88 + micro2 * 0.12
					g = 0.42 + rib * 0.16
					r = 0.40 + (1.0 - rib) * 0.25 + micro2 * 0.25
					ao = 0.72 + 0.28 * rib
					bump_amp = 3.20
				"corten_rust":
					# Deep weathering-steel oxide crust + powdery rust pits.
					var rust := _tile_noise(n_main, u * 3.0, v * 3.0, 3.0, 3.0)
					var pits := _tile_noise(n_fine, u * 9.0, v * 9.0, 9.0, 9.0)
					var pit_mask := smoothstep(0.55, 0.85, pits)
					h = rust * 0.65 - pit_mask * 0.35 + 0.2
					g = rust * 0.65 + (1.0 - pit_mask) * 0.35
					r = clampf(0.45 + pit_mask * 0.45 + (1.0 - rust) * 0.25, 0.0, 1.0)
					ao = 1.0 - pit_mask * 0.28
					bump_amp = 1.85
				"fabric_weave":
					# Orthogonal warp-over-weft basket weave.
					var wu := absf(sin(u * 16.0 * PI))
					var wv := absf(sin(v * 16.0 * PI))
					var checker := 1.0 if ((int(u * 16.0) + int(v * 16.0)) % 2 == 0) else 0.0
					var thread := wu * (0.35 + 0.65 * checker) + wv * (0.35 + 0.65 * (1.0 - checker))
					var fuzz := _tile_noise(n_fine, u * 8.0, v * 8.0, 8.0, 8.0)
					h = thread * 0.65 + fuzz * 0.35
					g = 0.38 + thread * 0.24
					r = 0.65 + (1.0 - thread * 0.35) * 0.30
					ao = 0.78 + 0.22 * clampf(thread * 0.7, 0.0, 1.0)
					bump_amp = 1.40
				"molded_plastic":
					# Fine EDM mold spark-erosion stipple.
					var stipple := _tile_noise(n_fine, u * 12.0, v * 12.0, 12.0, 12.0)
					var macro_p := _tile_noise(n_main, u * 2.0, v * 2.0, 2.0, 2.0)
					h = stipple * 0.80 + macro_p * 0.20
					g = 0.47 + stipple * 0.06
					r = 0.38 + stipple * 0.35 + macro_p * 0.15
					bump_amp = 0.75
				"concrete_earth":
					# Mineral sand aggregate + air-void pinholes.
					var base_c := _tile_noise(n_main, u * 3.0, v * 3.0, 3.0, 3.0)
					var grit := _tile_noise(n_fine, u * 10.0, v * 10.0, 10.0, 10.0)
					var void_p := smoothstep(0.72, 0.92, _tile_noise(n_cell, u * 6.0, v * 6.0, 6.0, 6.0))
					h = base_c * 0.50 + grit * 0.45 - void_p * 0.35 + 0.15
					g = base_c * 0.55 + grit * 0.35 - void_p * 0.20 + 0.10
					r = clampf(0.50 + grit * 0.35 + void_p * 0.20, 0.0, 1.0)
					ao = 1.0 - void_p * 0.32
					bump_amp = 1.70
				"pv_cell":
					# Subtle busbar/finger grid + tempered AR glass micro-ripple.
					var finger := 1.0 - smoothstep(0.0, 0.06, absf(fposmod(v * 8.0, 1.0) - 0.5))
					var bus := 1.0 - smoothstep(0.0, 0.035, absf(fposmod(u * 3.0, 1.0) - 0.5))
					var grid := clampf(maxf(finger * 0.35, bus * 0.75), 0.0, 1.0)
					var wav := _tile_noise(n_main, u * 2.0, v * 2.0, 2.0, 2.0)
					h = wav * 0.75 + grid * 0.25
					g = 0.46 + grid * 0.28
					r = clampf(0.25 + grid * 0.35 + wav * 0.12, 0.0, 1.0)
					bump_amp = 0.45
				_:
					# "smooth_glass" / "reflector": long-wavelength float/roll waviness.
					var roll := _tile_noise(n_main, u * 2.0, v * 1.0, 2.0, 1.0)
					h = roll
					g = 0.50
					r = 0.48 + roll * 0.08
					bump_amp = 0.35

			h_field[idx] = h
			g_field[idx] = g
			r_field[idx] = r
			ao_field[idx] = ao

	var alb_img := Image.create(sz, sz, false, Image.FORMAT_RGB8)
	var rgh_img := Image.create(sz, sz, false, Image.FORMAT_RGB8)
	var ao_img := Image.create(sz, sz, false, Image.FORMAT_RGB8)
	var nrm_img := Image.create(sz, sz, false, Image.FORMAT_RGB8)

	# Normalize grain mean to 1.0 so `albedo_color` never shifts darker/brighter overall.
	var g_mean := 0.0
	for i in g_field.size():
		g_mean += g_field[i]
	g_mean = maxf(g_mean / float(g_field.size()), 0.01)

	for y in sz:
		var ym := (y - 1 + sz) % sz
		var yp := (y + 1) % sz
		for x in sz:
			var xm := (x - 1 + sz) % sz
			var xp := (x + 1) % sz
			var idx := y * sz + x
			# Grain around 1.0 (`StandardMaterial3D` multiplies `albedo_color * albedo_texture`).
			var gv := clampf(1.0 + (g_field[idx] - g_mean) * gs * 0.85, 0.45, 1.0)
			alb_img.set_pixel(x, y, Color(gv, gv, gv, 1.0))
			# Roughness multiplier around 1.0 (`StandardMaterial3D` multiplies `roughness * roughness_texture.r`).
			var rv := clampf(1.0 + (r_field[idx] - 0.5) * rc * 0.95, 0.15, 1.0)
			rgh_img.set_pixel(x, y, Color(rv, rv, rv, 1.0))
			var av := clampf(ao_field[idx], 0.0, 1.0)
			ao_img.set_pixel(x, y, Color(av, av, av, 1.0))
			# Seamless central-difference tangent-space OpenGL normal (+X right, +Y down/V).
			var dhx := (h_field[y * sz + xp] - h_field[y * sz + xm]) * bump_amp
			var dhy := (h_field[yp * sz + x] - h_field[ym * sz + x]) * bump_amp
			var nvec := Vector3(-dhx, -dhy, 1.0).normalized()
			nrm_img.set_pixel(x, y, Color(nvec.x * 0.5 + 0.5, nvec.y * 0.5 + 0.5, nvec.z * 0.5 + 0.5, 1.0))

	alb_img.generate_mipmaps()
	rgh_img.generate_mipmaps()
	ao_img.generate_mipmaps()
	nrm_img.generate_mipmaps()

	var out := {
		"albedo": ImageTexture.create_from_image(alb_img),
		"normal": ImageTexture.create_from_image(nrm_img),
		"roughness": ImageTexture.create_from_image(rgh_img),
		"ao": ImageTexture.create_from_image(ao_img),
	}
	_proc_cache[key] = out
	return out


## Convert any color `Texture2D` or `Image` into a tint-neutral grayscale grain
## `ImageTexture` whose top end sits near 1.0 so `albedo_color` tints cleanly
## without darkening or brown-casting differently colored parametric parts.
static func normalize_albedo_to_grain(tex: Texture2D, cache_id: String, strength: float = 0.55) -> Texture2D:
	if tex == null:
		return null
	var st := snappedf(clampf(strength, 0.0, 1.0), 0.05)
	var key := "%s|%.2f" % [cache_id, st]
	if _grain_cache.has(key):
		return _grain_cache[key]
	var src := tex.get_image()
	if src == null or src.is_empty():
		return tex
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	# Cap working size to 512×512 so normalizing a 2K/4K upload stays instant (< 12 ms).
	if img.get_width() > 512 or img.get_height() > 512:
		img.resize(mini(img.get_width(), 512), mini(img.get_height(), 512), Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var mean := 0.0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			mean += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	var samples := maxi((w / 2) * (h / 2), 1)
	mean = maxf(mean / float(samples), 0.04)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var l := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			var ratio := clampf(l / mean, 0.35, 1.45)
			var g := clampf(lerpf(1.0, ratio * 0.94, st), 0.35, 1.0)
			img.set_pixel(x, y, Color(g, g, g, 1.0))
	img.generate_mipmaps()
	var out := ImageTexture.create_from_image(img)
	_grain_cache[key] = out
	return out


## Derive tangent-space OpenGL normal + roughness `ImageTexture`s from a single
## color image (used when a user uploads only an albedo/photo texture).
static func derive_normal_and_roughness(tex: Texture2D, cache_id: String, rough_contrast: float = 0.5) -> Dictionary:
	if tex == null:
		return {}
	var rc := snappedf(clampf(rough_contrast, 0.0, 1.0), 0.05)
	var key := "%s|%.2f" % [cache_id, rc]
	if _derived_cache.has(key):
		return _derived_cache[key]
	var src := tex.get_image()
	if src == null or src.is_empty():
		return {}
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	if img.get_width() > 512 or img.get_height() > 512:
		img.resize(mini(img.get_width(), 512), mini(img.get_height(), 512), Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var luma := PackedFloat32Array()
	luma.resize(w * h)
	var mean := 0.0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var l := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			luma[y * w + x] = l
			mean += l
	mean = maxf(mean / float(maxi(w * h, 1)), 0.04)

	var nrm := Image.create(w, h, false, Image.FORMAT_RGB8)
	var rgh := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		var ym := (y - 1 + h) % h
		var yp := (y + 1) % h
		for x in w:
			var xm := (x - 1 + w) % w
			var xp := (x + 1) % w
			var dhx := (luma[y * w + xp] - luma[y * w + xm]) * 2.4
			var dhy := (luma[yp * w + x] - luma[ym * w + x]) * 2.4
			var nvec := Vector3(-dhx, -dhy, 1.0).normalized()
			nrm.set_pixel(x, y, Color(nvec.x * 0.5 + 0.5, nvec.y * 0.5 + 0.5, nvec.z * 0.5 + 0.5, 1.0))
			# Darker crevices/pores read rougher; brighter facets read slightly smoother.
			var rel := clampf(1.0 - (luma[y * w + x] - mean) * rc * 1.2, 0.20, 1.0)
			rgh.set_pixel(x, y, Color(rel, rel, rel, 1.0))
	nrm.generate_mipmaps()
	rgh.generate_mipmaps()
	var out := {
		"normal": ImageTexture.create_from_image(nrm),
		"roughness": ImageTexture.create_from_image(rgh),
	}
	_derived_cache[key] = out
	return out


## Seamless 4D torus-mapped 2D noise in `[0, 1]` with periods `(px, py)` so tiles
## wrap across U and V with zero seam on `uv1_triplanar` surfaces.
static func _tile_noise(n: FastNoiseLite, x: float, y: float, px: float, py: float) -> float:
	var ax := (x / maxf(px, 1e-4)) * TAU
	var ay := (y / maxf(py, 1e-4)) * TAU
	var rx := maxf(px, 0.5) * 18.0
	var ry := maxf(py, 0.5) * 18.0
	# Map (u, v) onto two orthogonal circles embedded in 3D via shifted pair sample.
	var v1 := n.get_noise_3d(cos(ax) * rx, sin(ax) * rx, cos(ay) * ry)
	var v2 := n.get_noise_3d(sin(ay) * ry + 97.3, cos(ax) * rx - 41.7, sin(ax) * rx + 13.1)
	return clampf(0.5 + 0.36 * (v1 + v2), 0.0, 1.0)


static func _make_noise(seed_val: int, kind: FastNoiseLite.NoiseType, freq_scale: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_val & 0x7fffffff
	n.noise_type = kind
	n.frequency = 0.032 * freq_scale
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	return n


static func _make_cellular(seed_val: int, freq_scale: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_val & 0x7fffffff
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.frequency = 0.045 * freq_scale
	n.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	n.cellular_jitter = 0.85
	return n

class_name VegColorDetect
extends RefCounted

## Find the plants in the satellite photo: green → plants.
##
## The SOAK scene shipped an editor-time bake (VegetationScatter) that walked
## the photogrammetry mesh's albedo and dropped a shrub on every dark-green
## pixel. On desert and playa sites (SOAK, Bombay Beach) green stands out
## clearly against tan ground, and that beat the OSM polygon scatter, which
## knows nothing about where the individual bushes are. It only ever ran on
## that one scene. This is the same idea for any map, driven from the V
## toolbar's Detect tool: classify the drape under a region, split the green
## into patches, and turn each patch into plants sized by the patch.
##
## Classifier. Excess green on chromatic coordinates, ExG = 2g − r − b with
## r = R/(R+G+B) etc. (Woebbecke et al. 1995, the standard vegetation index for
## plain RGB imagery), plus a brightness cap (sun-bleached dry grass and bright
## sand are rejected even when slightly green). The ExG threshold is chosen
## per region by Otsu's method (1979) on the region's own histogram: on a site
## where green is clearly defined the histogram is bimodal and Otsu lands
## between ground and plants, which is what makes this automatic. The
## "sensitivity" knob shifts it. When the histogram is NOT bimodal (all bare
## ground, or all forest) the auto threshold falls back to FALLBACK_EXG.
##
## Patches. Cells passing the classifier are joined 8-connected. A patch up to
## `single_max_d_m` across (equivalent-circle diameter) is ONE plant at its
## centroid, sized to the patch — a desert shrub or a lone tree reads as one
## dark blob. A larger patch is canopy: it is filled with plants on a
## world-anchored jittered lattice at `spacing_m`, each sized to the spacing.
## Everything is deterministic: same photo, region and settings → same plants.
##
## Layers. Each layer is a drape image over a square of half-extent `half_m`
## centred on the site origin, the way TerrainLoader stores them. x is
## longitude-linear; y is Web-Mercator, so a world z (lat-linear) goes through
## TerrainBuilder.mercator_v_relative — the same correction the terrain shader
## applies. Layers are tried finest first; a point no layer covers is ignored.

const DEFAULTS := {
	"sensitivity": 0.0,      # -1 stricter … +1 looser (shifts the auto ExG cut)
	"max_luma": 0.62,        # brighter than this is never a plant
	"min_patch_m2": 1.0,     # smaller green specks are noise
	"single_max_d_m": 8.0,   # patches up to this across become one plant
	"spacing_m": 6.0,        # canopy fill spacing
	"cell_m": 0.0,           # raster cell (0 = auto from the area + the photo)
	"cap": 6000,
	"manual_exg": NAN,       # a fixed ExG cut instead of Otsu
}

## Otsu's cut on a near-unimodal histogram is noise: below this share of the
## total variance explained by the two classes, use FALLBACK_EXG.
const MIN_SEPARABILITY := 0.55
## Bright sand is ~0.02, dry grass ~0.1, healthy foliage 0.15–0.4.
const FALLBACK_EXG := 0.09
## Two-tone bare ground is bimodal too: Otsu then cuts between two sands. The
## class above the cut must actually be green (mean ExG) to be trusted.
const GREEN_CLASS_MIN := 0.07
const MIN_EXG_CUT := 0.025
const SENSITIVITY_SPAN := 0.07
## Raster budget: cells grow until the region fits this many.
const MAX_CELLS := 220000
const MIN_CELL_M := 0.5
const OTSU_BINS := 96
const EXG_LO := -0.4
const EXG_HI := 0.8

var _layers: Array = []   # [{img, w, h, half, lat_n, lat_s, mpp}]


## `lat_n/lat_s`: the layer's bbox latitudes (GeoMath.bbox_for). Pass 0/0 for
## a lat-linear image (the selftest's synthetic photo).
func add_layer(img: Image, half_m: float, lat_n: float = 0.0, lat_s: float = 0.0) -> void:
	if img == null or img.is_empty() or half_m <= 0.0:
		return
	_layers.append({
		"img": img, "w": img.get_width(), "h": img.get_height(), "half": half_m,
		"lat_n": lat_n, "lat_s": lat_s,
		"mpp": 2.0 * half_m / float(maxi(img.get_width(), 1)),
	})
	_layers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["mpp"]) < float(b["mpp"]))


func has_layers() -> bool:
	return not _layers.is_empty()


## The finest layer that covers (x, z): its metres per pixel, or INF.
func resolution_at(x: float, z: float) -> float:
	for l in _layers:
		var half := float(l["half"])
		if absf(x) < half and absf(z) < half:
			return float(l["mpp"])
	return INF


## Half-extent of the finest layer (the "whole hi-res area" square).
func finest_half_m() -> float:
	return float(_layers[0]["half"]) if not _layers.is_empty() else 0.0


## Drape colour at a world point; alpha 0 when no layer covers it.
func sample(x: float, z: float) -> Color:
	for l in _layers:
		var half := float(l["half"])
		if absf(x) >= half or absf(z) >= half:
			continue
		var u := (x + half) / (2.0 * half)
		var v := (z + half) / (2.0 * half)
		var lat_n := float(l["lat_n"])
		var lat_s := float(l["lat_s"])
		if absf(lat_n - lat_s) > 1e-9:
			v = TerrainBuilder.mercator_v_relative(v, lat_n, lat_s)
		var img: Image = l["img"]
		var px := clampi(int(u * float(l["w"])), 0, int(l["w"]) - 1)
		var py := clampi(int(v * float(l["h"])), 0, int(l["h"]) - 1)
		var c := img.get_pixel(px, py)
		c.a = 1.0
		return c
	return Color(0, 0, 0, 0)


## The finest layer that covers the whole rectangle, else the one covering
## its centre, else the coarsest. Detection reads ONE photo per run: mixing
## a 0.2 m patch and a 15 m base drape inside one region would put a hard
## threshold seam through it.
func _layer_for_rect(r: Rect2) -> Dictionary:
	if _layers.is_empty():
		return {}
	var c := r.get_center()
	var centre_hit: Dictionary = {}
	for l in _layers:
		var half := float(l["half"])
		if r.position.x >= -half and r.position.y >= -half \
				and r.end.x <= half and r.end.y <= half:
			return l
		if centre_hit.is_empty() and absf(c.x) < half and absf(c.y) < half:
			centre_hit = l
	return centre_hit if not centre_hit.is_empty() else _layers.back()


## The layer's pixels under a world rectangle, box-filtered down to nx × nz
## (one pixel per detection cell) in native code — a per-cell get_pixel loop
## at 4 samples a cell cost seconds per preview.
func _resample(l: Dictionary, r: Rect2, nx: int, nz: int) -> Image:
	var img: Image = l["img"]
	var half := float(l["half"])
	var w := int(l["w"])
	var h := int(l["h"])
	var u0 := (r.position.x + half) / (2.0 * half)
	var u1 := (r.end.x + half) / (2.0 * half)
	var v0 := _v_for(l, (r.position.y + half) / (2.0 * half))
	var v1 := _v_for(l, (r.end.y + half) / (2.0 * half))
	var px0 := clampi(int(floor(u0 * float(w))), 0, w - 1)
	var px1 := clampi(int(ceil(u1 * float(w))), px0 + 1, w)
	var py0 := clampi(int(floor(v0 * float(h))), 0, h - 1)
	var py1 := clampi(int(ceil(v1 * float(h))), py0 + 1, h)
	var crop := img.get_region(Rect2i(px0, py0, px1 - px0, py1 - py0))
	if crop == null or crop.is_empty():
		return null
	if crop.get_format() != Image.FORMAT_RGBA8:
		crop.convert(Image.FORMAT_RGBA8)
	# Pad the crop back out to the full rectangle where it ran off the photo,
	# so cell (ix, iz) stays at its world position.
	var full_w := maxi(int(round((u1 - u0) * float(w))), 1)
	var full_h := maxi(int(round((v1 - v0) * float(h))), 1)
	if crop.get_width() != full_w or crop.get_height() != full_h:
		var canvas := Image.create(full_w, full_h, false, Image.FORMAT_RGBA8)
		canvas.fill(Color(0, 0, 0, 0))
		var ox := int(round((float(px0) / float(w) - u0) * float(w)))
		var oy := int(round((float(py0) / float(h) - v0) * float(h)))
		canvas.blit_rect(crop, Rect2i(0, 0, crop.get_width(), crop.get_height()),
			Vector2i(ox, oy))
		crop = canvas
	while crop.get_width() >= nx * 2 and crop.get_height() >= nz * 2:
		crop.shrink_x2()
	crop.resize(nx, nz, Image.INTERPOLATE_BILINEAR)
	return crop


static func _v_for(l: Dictionary, v_lin: float) -> float:
	var lat_n := float(l["lat_n"])
	var lat_s := float(l["lat_s"])
	if absf(lat_n - lat_s) < 1e-9:
		return v_lin
	return TerrainBuilder.mercator_v_relative(v_lin, lat_n, lat_s)


static func exg(c: Color) -> float:
	var s := c.r + c.g + c.b
	if s < 0.02:
		return 0.0
	return (2.0 * c.g - c.r - c.b) / s


static func luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## Otsu's threshold over values in [lo, hi]. Returns {cut, separability} —
## separability = between-class / total variance (0..1).
static func otsu(values: PackedFloat32Array, lo: float = EXG_LO, hi: float = EXG_HI,
		bins: int = OTSU_BINS) -> Dictionary:
	if values.is_empty():
		return {"cut": FALLBACK_EXG, "separability": 0.0}
	var hist := PackedFloat64Array()
	hist.resize(bins)
	var span := hi - lo
	var total := 0.0
	var mean_all := 0.0
	for v in values:
		var b := clampi(int((v - lo) / span * float(bins)), 0, bins - 1)
		hist[b] += 1.0
	for b in bins:
		total += hist[b]
		mean_all += hist[b] * float(b)
	mean_all /= total
	var var_all := 0.0
	for b in bins:
		var dd := float(b) - mean_all
		var_all += hist[b] * dd * dd
	var_all /= total
	var w0 := 0.0
	var sum0 := 0.0
	var best := -1.0
	var best_b := 0
	var best_m1 := 0.0
	for b in bins:
		w0 += hist[b]
		sum0 += hist[b] * float(b)
		var w1 := total - w0
		if w0 <= 0.0 or w1 <= 0.0:
			continue
		var m0 := sum0 / w0
		var m1 := (mean_all * total - sum0) / w1
		var between := (w0 / total) * (w1 / total) * (m0 - m1) * (m0 - m1)
		if between > best:
			best = between
			best_b = b
			best_m1 = m1
	var sep := best / var_all if var_all > 1e-12 else 0.0
	return {"cut": lo + (float(best_b) + 1.0) / float(bins) * span, "separability": sep,
		"upper_mean": lo + (best_m1 + 0.5) / float(bins) * span}


## Run the whole detection over `poly` (world XZ). Returns
## {plants: [{x, z, d_m, area_m2, canopy}], cut, auto, separability, cell_m,
##  green_m2, area_m2, patches, mpp, mask: {origin, cell, w, h, bits}}.
## `canopy` = the plant came from filling a large patch.
func detect(poly: PackedVector2Array, params: Dictionary = {}) -> Dictionary:
	var p := DEFAULTS.duplicate()
	p.merge(params, true)
	var out := {"plants": [], "cut": NAN, "auto": true, "separability": 0.0,
		"cell_m": 0.0, "green_m2": 0.0, "area_m2": 0.0, "patches": 0, "mpp": INF,
		"mask": {}}
	if poly.size() < 3 or _layers.is_empty():
		return out
	var bb := VegetationPaint.polygon_aabb(poly)
	var area := VegetationPaint.polygon_area(poly)
	out["area_m2"] = area
	var layer := _layer_for_rect(bb)
	if layer.is_empty():
		return out
	var mpp := float(layer["mpp"])
	out["mpp"] = mpp
	var cell := float(p["cell_m"])
	if cell <= 0.0:
		cell = maxf(maxf(MIN_CELL_M, mpp * 1.5), sqrt(bb.size.x * bb.size.y / float(MAX_CELLS)))
	out["cell_m"] = cell
	var nx := maxi(int(ceil(bb.size.x / cell)), 1)
	var nz := maxi(int(ceil(bb.size.y / cell)), 1)
	var n := nx * nz
	var grid := _resample(layer, Rect2(bb.position, Vector2(float(nx), float(nz)) * cell), nx, nz)
	if grid == null:
		return out
	# Per cell: ExG (NAN = outside the region or the photo) and brightness.
	var exgs := PackedFloat32Array()
	exgs.resize(n)
	var lumas := PackedFloat32Array()
	lumas.resize(n)
	var valid := PackedFloat32Array()
	var half := float(layer["half"])
	for iz in nz:
		var wz := bb.position.y + (float(iz) + 0.5) * cell
		for ix in nx:
			var i := iz * nx + ix
			var wx := bb.position.x + (float(ix) + 0.5) * cell
			if absf(wx) >= half or absf(wz) >= half \
					or not Geometry2D.is_point_in_polygon(Vector2(wx, wz), poly):
				exgs[i] = NAN
				continue
			var c := grid.get_pixel(ix, iz)
			var e := exg(c)
			exgs[i] = e
			lumas[i] = luma(c)
			valid.append(e)
	if valid.is_empty():
		return out
	var cut := float(p["manual_exg"])
	if is_nan(cut):
		var ot := otsu(valid)
		out["separability"] = float(ot["separability"])
		var trusted := float(ot["separability"]) >= MIN_SEPARABILITY 			and float(ot.get("upper_mean", 0.0)) >= GREEN_CLASS_MIN
		out["auto_split"] = trusted
		cut = float(ot["cut"]) if trusted else FALLBACK_EXG
		cut = maxf(cut - clampf(float(p["sensitivity"]), -1.0, 1.0) * SENSITIVITY_SPAN, MIN_EXG_CUT)
	else:
		out["auto"] = false
	out["cut"] = cut
	var max_l := float(p["max_luma"])
	var mask := PackedByteArray()
	mask.resize(n)
	var green := 0
	for i in n:
		var e := exgs[i]
		if not is_nan(e) and e >= cut and lumas[i] <= max_l:
			mask[i] = 1
			green += 1
	out["green_m2"] = float(green) * cell * cell
	out["mask"] = {"origin": bb.position, "cell": cell, "w": nx, "h": nz, "bits": mask}
	var plants := _plants_from_mask(mask, nx, nz, bb.position, cell, p, exgs)
	out["plants"] = plants["plants"]
	out["patches"] = int(plants["patches"])
	return out


func _plants_from_mask(mask: PackedByteArray, nx: int, nz: int, origin: Vector2,
		cell: float, p: Dictionary, exgs: PackedFloat32Array) -> Dictionary:
	var labels := PackedInt32Array()
	labels.resize(mask.size())
	var plants: Array = []
	var patches := 0
	var min_area := float(p["min_patch_m2"])
	var single_max := float(p["single_max_d_m"])
	var spacing := maxf(float(p["spacing_m"]), 0.5)
	var cap := int(p["cap"])
	var stack := PackedInt32Array()
	var next_label := 0
	for start in mask.size():
		if mask[start] == 0 or labels[start] != 0:
			continue
		next_label += 1
		labels[start] = next_label
		stack.clear()
		stack.append(start)
		var cells := PackedInt32Array()
		var sx := 0.0
		var sz := 0.0
		var se := 0.0
		while not stack.is_empty():
			var c := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			cells.append(c)
			var cx := c % nx
			var cz := c / nx
			sx += float(cx)
			sz += float(cz)
			se += exgs[c]
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dz == 0:
						continue
					var x2 := cx + dx
					var z2 := cz + dz
					if x2 < 0 or z2 < 0 or x2 >= nx or z2 >= nz:
						continue
					var j := z2 * nx + x2
					if mask[j] == 1 and labels[j] == 0:
						labels[j] = next_label
						stack.append(j)
		var a := float(cells.size()) * cell * cell
		if a < min_area:
			continue
		patches += 1
		var d_eq := 2.0 * sqrt(a / PI)
		var mean_e := se / float(cells.size())
		if d_eq <= single_max:
			var fx := origin.x + (sx / float(cells.size()) + 0.5) * cell
			var fz := origin.y + (sz / float(cells.size()) + 0.5) * cell
			plants.append({"x": fx, "z": fz, "d_m": d_eq, "area_m2": a,
				"canopy": false, "exg": mean_e})
		else:
			_fill_patch(cells, labels, next_label, nx, origin, cell, spacing, mean_e, plants)
		if plants.size() >= cap:
			plants.resize(cap)
			break
	return {"plants": plants, "patches": patches}


## Canopy patch → plants on a world-anchored lattice at `spacing`, jittered by
## a hash of the lattice cell so a re-run (or a bigger region) puts the same
## tree in the same place.
static func _fill_patch(cells: PackedInt32Array, labels: PackedInt32Array, label: int,
		nx: int, origin: Vector2, cell: float, spacing: float, mean_e: float,
		plants: Array) -> void:
	var minx := INF
	var minz := INF
	var maxx := -INF
	var maxz := -INF
	for c in cells:
		var wx := origin.x + (float(c % nx) + 0.5) * cell
		var wz := origin.y + (float(c / nx) + 0.5) * cell
		minx = minf(minx, wx)
		maxx = maxf(maxx, wx)
		minz = minf(minz, wz)
		maxz = maxf(maxz, wz)
	var row_h := spacing * 0.866
	var r0 := floori(minz / row_h) - 1
	var r1 := ceili(maxz / row_h) + 1
	for row in range(r0, r1 + 1):
		var off := 0.5 if (row & 1) != 0 else 0.0
		var c0 := floori(minx / spacing) - 1
		var c1 := ceili(maxx / spacing) + 1
		for col in range(c0, c1 + 1):
			var hj := absi(hash(Vector2i(col, row)))
			var jx := (float(hj % 1000) / 1000.0 - 0.5) * spacing * 0.5
			var jz := (float((hj / 1000) % 1000) / 1000.0 - 0.5) * row_h * 0.5
			var wx := (float(col) + off) * spacing + jx
			var wz := float(row) * row_h + jz
			var ix := int(floor((wx - origin.x) / cell))
			var iz := int(floor((wz - origin.y) / cell))
			if ix < 0 or iz < 0 or ix >= nx:
				continue
			var idx := iz * nx + ix
			if idx >= labels.size() or labels[idx] != label:
				continue
			plants.append({"x": wx, "z": wz, "d_m": spacing * 0.95,
				"area_m2": spacing * row_h, "canopy": true, "exg": mean_e})


## The mask as an RGBA image for the in-world preview: green where plants
## were found, clear elsewhere.
static func mask_image(mask: Dictionary, color: Color = Color(0.25, 1.0, 0.35, 0.6)) -> Image:
	var w := int(mask.get("w", 0))
	var h := int(mask.get("h", 0))
	var bits: PackedByteArray = mask.get("bits", PackedByteArray())
	if w <= 0 or h <= 0 or bits.size() < w * h:
		return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in w * h:
		if bits[i] == 1:
			img.set_pixel(i % w, i / w, color)
	return img

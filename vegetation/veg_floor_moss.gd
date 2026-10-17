class_name VegFloorMoss
extends RefCounted

## Forest-floor moss (2026-10-15): a coverage mask of where the canopy shades
## the ground, which terrain_detail.gdshader paints moss-green (patchy, under
## the drape) when the style's `forest_floor_moss` is above 0.
##
## Unlike the leaf-litter mask (25 m texels over the whole map) this one is
## fitted to the FORESTED rectangle at ~2 m a texel: moss under a stand is a
## few-metre thing, and the site is where the player looks. Trees stamp a soft
## disc the size of their shade; understory plants add a little. Built from the
## painted records (+ the generated forest inside DETAIL_HALF_M of the site).
##
## Style keys: forest_floor_moss (0 = off, the default), forest_floor_moss_color.

const KEY := "forest_floor_moss"
const KEY_COLOR := "forest_floor_moss_color"
const DEFAULT_COLOR := Color(0.22, 0.34, 0.08)
const TEXEL_M := 2.0
const MAX_PX := 1024
const PAD_M := 12.0
const DETAIL_HALF_M := 1500.0


static func strength(settings: Dictionary) -> float:
	return clampf(float(settings.get(KEY, 0.0)), 0.0, 1.0)


## {tex: ImageTexture, rect: Vector4(x0, z0, size_m, 0)} or {} (nothing to draw).
static func build(bulks: Array) -> Dictionary:
	var pts: Array = []   # [x, z, radius, weight]
	for bulk in bulks:
		if not (bulk is Dictionary):
			continue
		for slot in (bulk as Dictionary):
			var sid := str(slot)
			var fam := VegSpeciesCatalog.mesh_family(sid)
			var r := 0.0
			var wgt := 0.0
			if fam == "pine":
				r = 4.5
				wgt = 0.55
			elif fam == "deciduous":
				r = 5.0
				wgt = 0.45
			elif sid in VegSpeciesCatalog.UNDERSTORY_IDS:
				r = 1.6
				wgt = 0.25
			else:
				continue
			for item in (bulk as Dictionary)[slot]:
				if not (item is Dictionary):
					continue
				var d: Dictionary = item
				var x := float(d.get("x", 0.0))
				var z := float(d.get("z", 0.0))
				if absf(x) > DETAIL_HALF_M or absf(z) > DETAIL_HALF_M:
					continue
				pts.append([x, z, r * clampf(float(d.get("scale", 1.0)), 0.5, 2.0), wgt])
	if pts.is_empty():
		return {}
	var x0 := INF
	var z0 := INF
	var x1 := -INF
	var z1 := -INF
	for p in pts:
		x0 = minf(x0, float(p[0]))
		z0 = minf(z0, float(p[1]))
		x1 = maxf(x1, float(p[0]))
		z1 = maxf(z1, float(p[1]))
	var size_m := maxf(x1 - x0, z1 - z0) + PAD_M * 2.0
	x0 -= PAD_M
	z0 -= PAD_M
	var px := clampi(int(ceil(size_m / TEXEL_M)), 16, MAX_PX)
	var texel := size_m / float(px)
	var acc := PackedFloat32Array()
	acc.resize(px * px)
	for p in pts:
		var cx := (float(p[0]) - x0) / texel
		var cz := (float(p[1]) - z0) / texel
		var rr := float(p[2]) / texel
		var w := float(p[3])
		var i0 := maxi(int(cx - rr), 0)
		var i1 := mini(int(cx + rr) + 1, px - 1)
		var j0 := maxi(int(cz - rr), 0)
		var j1 := mini(int(cz + rr) + 1, px - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var dd := Vector2(float(i) + 0.5 - cx, float(j) + 0.5 - cz).length() / maxf(rr, 0.01)
				if dd >= 1.0:
					continue
				var k := j * px + i
				acc[k] = minf(acc[k] + w * (1.0 - dd * dd), 1.0)
	var img := Image.create_empty(px, px, false, Image.FORMAT_R8)
	for j in px:
		for i in px:
			var v := acc[j * px + i]
			if v > 0.0:
				img.set_pixel(i, j, Color(v, 0.0, 0.0))
	return {"tex": ImageTexture.create_from_image(img), "rect": Vector4(x0, z0, size_m, 0.0)}

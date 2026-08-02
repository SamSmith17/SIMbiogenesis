class_name VegLitterMask
extends RefCounted

## Ground leaf-litter coverage mask (veg overhaul Phase 6).
##
## Rasterises the scattered DECIDUOUS instances into a small single-channel
## image over the map's centred world-XZ frame — the same frame the terrain
## drape uses, so terrain_detail.gdshader can address it with one uniform pair
## (`litter_tex` + `litter_extent_m`) and no per-vertex data.
##
## Resolution is chosen from the map extent, NOT fixed: a fixed 256² over a
## 30 km map is 117 m per texel, and one street tree then browned a 350 m circle
## of hillside — the whole foreground went brown in winter. TARGET_TEXEL_M keeps
## a texel near canopy scale whatever the map size (1024² over 30 km ≈ 29 m,
## 1 MB). Conifers are excluded — needle drop is a different, far subtler thing,
## and including them turned every evergreen slope brown.

const MIN_MASK_PX := 256
const MAX_MASK_PX := 1024
const TARGET_TEXEL_M := 25.0
## Coverage added per instance. Low on purpose: a closed stand accumulates to a
## solid tint over a few trees, while a handful of scattered street trees stays
## barely visible.
const STAMP_WEIGHT := 0.28
## Families that shed a real leaf layer. Keep in step with
## VegLeafFall.SHEDDING_FAMILIES.
const LITTER_FAMILIES := ["deciduous"]


## Build a coverage mask from an auto/manual layer's `bulk` dictionary
## (slot -> [{x, z, ...}]). Returns null when the map carries no deciduous
## instances at all, which is the caller's signal to disable the whole layer.
static func build(bulk: Dictionary, extent_m: float) -> ImageTexture:
	if bulk.is_empty() or extent_m <= 0.0:
		return null
	var px := mask_px_for_extent(extent_m)
	var img := Image.create_empty(px, px, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0, 1))
	var stamped := 0
	for slot in bulk:
		if not _sheds(str(slot)):
			continue
		var records: Variant = bulk[slot]
		if not (records is Array):
			continue
		for item in records as Array:
			if not (item is Dictionary):
				continue
			var d: Dictionary = item
			if _stamp(img, float(d.get("x", 0.0)), float(d.get("z", 0.0)), extent_m):
				stamped += 1
	if stamped == 0:
		return null
	return ImageTexture.create_from_image(img)


## Mask side in texels for a map extent, clamped to the memory budget.
static func mask_px_for_extent(extent_m: float) -> int:
	var want := int(round(extent_m / TARGET_TEXEL_M))
	return clampi(nearest_po2(maxi(want, 1)), MIN_MASK_PX, MAX_MASK_PX)


static func _sheds(slot: String) -> bool:
	return VegSpeciesCatalog.mesh_family(slot) in LITTER_FAMILIES


## Accumulate one instance's coverage. Returns false when the instance falls
## outside the mask's extent (so the caller can tell "no deciduous trees" from
## "deciduous trees, all off-map").
## Accumulate one instance into its own texel only. A wider stamp was what made
## isolated trees brown whole hillsides; at ~25 m per texel a tree's canopy is
## smaller than one texel anyway, and the shader's linear filtering plus its
## noise break-up soften the edge.
static func _stamp(img: Image, x: float, z: float, extent_m: float) -> bool:
	var u := (x + extent_m * 0.5) / extent_m
	var v := (z + extent_m * 0.5) / extent_m
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return false
	var side := img.get_width()
	var px := clampi(int(u * float(side - 1)), 0, side - 1)
	var pz := clampi(int(v * float(side - 1)), 0, side - 1)
	var cur := img.get_pixel(px, pz).r
	img.set_pixel(px, pz, Color(minf(cur + STAMP_WEIGHT, 1.0), 0.0, 0.0))
	return true


## Seasonal litter strength 0..1 from the phenology signals. Litter accumulates
## as the canopy empties, survives the winter, and is gone by the time the new
## canopy is out; snow buries it.
static func strength_for_season(season: Dictionary, snow_amount: float) -> float:
	if season.is_empty():
		return 0.0
	var coverage := clampf(float(season.get("leaf_coverage", 1.0)), 0.0, 1.0)
	var bud := clampf(float(season.get("bud", 0.0)), 0.0, 1.0)
	# The latitude damping already zeroes coverage swing in the tropics, but
	# read it directly too so a site with no seasonality never browns at all.
	var seasonality := clampf(float(season.get("seasonality", 1.0)), 0.0, 1.0)
	var fallen := (1.0 - coverage) * seasonality
	# Spring: the new canopy comes out over last year's litter, which rots away.
	fallen *= 1.0 - bud * 0.8
	fallen *= 1.0 - clampf(snow_amount, 0.0, 1.0)
	return clampf(fallen, 0.0, 1.0)

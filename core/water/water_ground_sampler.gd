class_name WaterGroundSampler
extends RefCounted

## A frozen copy of the terrain's BASE height inputs (the composed DEM footing,
## WITHOUT any edit tiles), so channel carving and flow routing can sample the
## ground on a worker thread without touching the TerrainLoader node. Packed
## arrays are copy-on-write: the loader swapping its grids later never changes
## what an in-flight job sees.
##
## `base_at` mirrors TerrainLoader._dem_height_without_earthworks exactly (same
## TerrainBuilder.sample_footing_height call), which is what the HeightField's
## base_fn uses — so a carve computed here lines up with the rendered tiles.
## Optional `layers` (TerrainEditTiles) are added by `surface_at` for queries
## that want the edited surface (flow routing over sculpted ground).

var coarse := PackedFloat32Array()
var coarse_res := 0
var coarse_extent_m := 0.0
var center_elev := 0.0
var detail := PackedFloat32Array()
var detail_cols := 0
var detail_rows := 0
var detail_extent_m := 0.0
var fallback := PackedFloat32Array()
var flat_y := 0.0
var layers: Array = []
## Explicit carve half-extent (m); < 0 = derive from the detail grid. Lets a
## synthetic (height_fn) sampler define a patch.
var patch_half_m := -1.0


## A sampler over a synthetic height function — selftests and the offline
## routing checks use this instead of grids.
var height_fn: Callable = Callable()


static func from_fn(fn: Callable) -> WaterGroundSampler:
	var s := WaterGroundSampler.new()
	s.height_fn = fn
	return s


func base_at(x: float, z: float) -> float:
	if height_fn.is_valid():
		return float(height_fn.call(x, z))
	if coarse.is_empty() and detail.is_empty():
		return flat_y
	return TerrainBuilder.sample_footing_height(
		x, z, coarse, coarse_res, coarse_extent_m, center_elev,
		detail, detail_cols, detail_rows, detail_extent_m, fallback)


func delta_at(x: float, z: float) -> float:
	var d := 0.0
	for l in layers:
		var t := l as TerrainEditTiles
		if t != null:
			d += t.sample_delta(x, z)
	return d


func surface_at(x: float, z: float) -> float:
	return base_at(x, z) + delta_at(x, z)


## Half the side of the hi-res detail square (0 when there is none). Channels
## are only carved inside it — the coarse Ground outside is never sunk.
func detail_half() -> float:
	if patch_half_m >= 0.0:
		return patch_half_m
	return detail_extent_m * 0.5 if not detail.is_empty() else 0.0

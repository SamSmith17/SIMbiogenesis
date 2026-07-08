class_name TerrainLoadProgress
extends RefCounted

## Weighted multi-stage load tracker for generated maps. Each stage contributes a
## fixed share of [0..1]; in-flight fetches use set_partial() for sub-progress.

const STAGE_ORDER: Array[String] = [
	"base_dem", "base_img", "walkable", "detail_dem", "detail_img", "osm_map", "osm_veg",
]

const STAGE_LABELS: Dictionary = {
	"base_dem": "Elevation",
	"base_img": "Satellite imagery",
	"walkable": "Building terrain",
	"detail_dem": "Hi-res elevation",
	"detail_img": "Hi-res imagery",
	"osm_map": "OSM map data",
	"osm_veg": "Vegetation",
}

const STAGE_WEIGHTS: Dictionary = {
	"base_dem": 0.14,
	"base_img": 0.20,
	"walkable": 0.06,
	"detail_dem": 0.12,
	"detail_img": 0.14,
	"osm_map": 0.16,
	"osm_veg": 0.18,
}

var _done: Dictionary = {}
var _partial: Dictionary = {}
var _extent_labels: Dictionary = {}


func reset() -> void:
	_done.clear()
	_partial.clear()
	_extent_labels.clear()


## Optional per-load labels that include the configured world/hi-res radii.
func configure_for_extents(world_half_m: float, detail_half_m: float) -> void:
	var world_km := world_half_m * 2.0 / 1000.0
	var detail_km := detail_half_m * 2.0 / 1000.0
	_extent_labels = {
		"base_dem": "Elevation (%.0f km world)" % world_km,
		"detail_dem": "Hi-res elevation (%.1f km)" % detail_km,
		"detail_img": "Hi-res imagery (%.1f km)" % detail_km,
	}


func mark_done(stage: String) -> void:
	if stage not in STAGE_WEIGHTS:
		return
	_done[stage] = true
	_partial[stage] = 1.0


func is_done(stage: String) -> bool:
	return bool(_done.get(stage, false))


func set_partial(stage: String, ratio: float) -> void:
	if stage not in STAGE_WEIGHTS or is_done(stage):
		return
	_partial[stage] = clampf(ratio, 0.0, 1.0)


func fraction() -> float:
	var total := 0.0
	for stage in STAGE_WEIGHTS:
		var w := float(STAGE_WEIGHTS[stage])
		if is_done(stage):
			total += w
		else:
			total += w * float(_partial.get(stage, 0.0))
	return clampf(total, 0.0, 1.0)


func active_stage_id() -> String:
	for stage in STAGE_ORDER:
		if not is_done(stage):
			return stage
	return ""


func active_label() -> String:
	var sid := active_stage_id()
	if sid.is_empty():
		return "Map loaded"
	if sid in _extent_labels:
		return str(_extent_labels[sid])
	return str(STAGE_LABELS.get(sid, sid))


func is_complete() -> bool:
	for stage in STAGE_WEIGHTS:
		if not is_done(stage):
			return false
	return true

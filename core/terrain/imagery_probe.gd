extends SceneTree

## Offline probe (no network): prints the zoom / tile-count / stitched-image size
## the ImageryService would allocate for the live base + detail imagery requests.
## Run: godot --headless --path . --script core/terrain/imagery_probe.gd

const LAT := 42.4297785
const LON := -71.3033877
const BASE_HALF := 15000.0
const DETAIL_HALF := 1500.0
const BASE_TARGET := 2048
const DETAIL_TARGET := 2048
const DETAIL_MAX_ZOOM := 18
const TILE_PX := 256


func _initialize() -> void:
	_probe("base", BASE_HALF, BASE_TARGET, 17)
	_probe("detail", DETAIL_HALF, DETAIL_TARGET, DETAIL_MAX_ZOOM)
	quit(0)


func _probe(tag: String, half: float, target_px: int, max_zoom: int) -> void:
	var bbox := GeoMath.bbox_for(LAT, LON, half)
	var z := GeoMath.pick_zoom(bbox, target_px, max_zoom)
	var rng := GeoMath.tile_range_for_bbox(bbox, z)
	var cols := int(rng["max_x"]) - int(rng["min_x"]) + 1
	var rows := int(rng["max_y"]) - int(rng["min_y"]) + 1
	var w := cols * TILE_PX
	var h := rows * TILE_PX
	var n_tiles := cols * rows
	var mb := float(w) * float(h) * 3.0 / 1048576.0
	print("%-7s half=%.0fm z=%d tiles=%dx%d=%d stitched=%dx%d (%.1f MB RGB8)" % [
		tag, half, z, cols, rows, n_tiles, w, h, mb])

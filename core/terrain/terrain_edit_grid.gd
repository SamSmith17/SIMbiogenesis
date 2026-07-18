class_name TerrainEditGrid
extends RefCounted

## Per-map user terrain edits stored as height delta grids aligned to the terrain
## mesh.
##
## Two layers:
##  - `delta` (coarse, MESH_RES over the full ~30 km map, ~120 m/cell) — legacy
##    rect-op edits, kept for backward compatibility with v1 saves and for coarse,
##    far-from-site edits. Applied by bilinear upsample onto the detail patch.
##  - `detail_delta` (detail res over the ~3 km detail patch, ~12 m/cell) — the
##    high-precision sculpt layer written by the brush/shape/pond tools. Applied
##    directly onto the composed detail surface.

const VERSION := 2


static func create_empty(res: int) -> TerrainEditGrid:
	var g := TerrainEditGrid.new()
	g.res = res
	g.delta = PackedFloat32Array()
	g.delta.resize(res * res)
	return g


var res: int = 0
var delta: PackedFloat32Array = PackedFloat32Array()
var osm_auto_delta: PackedFloat32Array = PackedFloat32Array()
## High-precision detail-patch sculpt layer (see class docs).
var detail_res: int = 0
var detail_extent_m: float = 0.0
var detail_delta: PackedFloat32Array = PackedFloat32Array()


## Allocate (or re-fit) the detail sculpt grid to match the current detail patch.
## When the detail resolution changes mid-session (e.g. a hi-res DEM arrives after a
## coarse one), the existing edits are resampled so sculpted features are preserved.
func ensure_detail(new_res: int, extent_m: float) -> void:
	if new_res < 2 or extent_m <= 0.0:
		return
	var want := new_res * new_res
	if detail_delta.size() == want and detail_res == new_res \
			and is_equal_approx(detail_extent_m, extent_m):
		return
	if not detail_delta.is_empty() and detail_res >= 2 \
			and detail_delta.size() == detail_res * detail_res:
		# Preserve edits across a resolution change (extent is a fixed map property).
		detail_delta = TerrainBuilder.resample(detail_delta, detail_res, detail_res, new_res)
	else:
		detail_delta = PackedFloat32Array()
		detail_delta.resize(want)
	detail_res = new_res
	detail_extent_m = extent_m


func has_detail_edits() -> bool:
	for v in detail_delta:
		if absf(v) > 1e-4:
			return true
	return false


func apply_to(base: PackedFloat32Array) -> PackedFloat32Array:
	var out := base.duplicate()
	if delta.is_empty() or out.size() != delta.size():
		return out
	for i in out.size():
		out[i] += delta[i]
	return out


## Add the detail sculpt layer onto a composed detail-patch grid (res × res over
## `extent`). Resamples the stored delta when the target resolution differs.
func apply_detail_to(base: PackedFloat32Array, target_res: int, extent_m: float) -> PackedFloat32Array:
	var out := base.duplicate()
	if detail_delta.is_empty() or detail_res < 2:
		return out
	if target_res == detail_res and out.size() == detail_delta.size():
		for i in out.size():
			out[i] += detail_delta[i]
		return out
	var scaled := TerrainBuilder.resample(detail_delta, detail_res, detail_res, target_res)
	var n := mini(out.size(), scaled.size())
	for i in n:
		out[i] += scaled[i]
	return out


func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/terrain_edit_%s_%s.json" % [_coord_token(lat), _coord_token(lon)]


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"version": VERSION,
		"res": res,
		"delta": Array(delta),
		"detail_res": detail_res,
		"detail_extent_m": detail_extent_m,
		"detail_delta": Array(detail_delta),
	}))


func load_for_map(lat: float, lon: float) -> bool:
	var path := save_path_for_map(lat, lon)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	var d: Dictionary = parsed
	res = int(d.get("res", 0))
	delta = PackedFloat32Array()
	for v in (d.get("delta", []) as Array):
		delta.append(TerrainBuilder.variant_to_float(v, 0.0))
	# v2 detail sculpt layer (absent in v1 saves → stays empty, migrated lazily).
	detail_res = int(d.get("detail_res", 0))
	detail_extent_m = TerrainBuilder.variant_to_float(d.get("detail_extent_m", 0.0), 0.0)
	detail_delta = PackedFloat32Array()
	for v in (d.get("detail_delta", []) as Array):
		detail_delta.append(TerrainBuilder.variant_to_float(v, 0.0))
	if detail_res >= 2 and detail_delta.size() != detail_res * detail_res:
		detail_delta = PackedFloat32Array()
		detail_res = 0
	return delta.size() == res * res


static func _coord_token(v: float) -> String:
	var s := "%.4f" % absf(v)
	return ("n" if v < 0.0 else "") + s.replace(".", "p")

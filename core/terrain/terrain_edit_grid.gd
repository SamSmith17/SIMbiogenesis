class_name TerrainEditGrid
extends RefCounted

## Per-map user terrain edits stored as a delta grid aligned to the terrain mesh.

const VERSION := 1


static func create_empty(res: int) -> TerrainEditGrid:
	var g := TerrainEditGrid.new()
	g.res = res
	g.delta = PackedFloat32Array()
	g.delta.resize(res * res)
	return g


var res: int = 0
var delta: PackedFloat32Array = PackedFloat32Array()
var osm_auto_delta: PackedFloat32Array = PackedFloat32Array()


func apply_to(base: PackedFloat32Array) -> PackedFloat32Array:
	var out := base.duplicate()
	if delta.is_empty() or out.size() != delta.size():
		return out
	for i in out.size():
		out[i] += delta[i]
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
	return delta.size() == res * res


static func _coord_token(v: float) -> String:
	var s := "%.4f" % absf(v)
	return ("n" if v < 0.0 else "") + s.replace(".", "p")

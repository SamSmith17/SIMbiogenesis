class_name WindowWallViewpoint
extends RefCounted

## The per-site "bus parking spot" the Window Wall opens at: a ground point and
## a heading. Pitch is always zero — the wall is vertical and the horizon must
## be level across the bezels — and the eye sits `seat_eye_height_m` (a global
## pref) above `pos`, so re-seating the chair does not need every map re-saved.
##
## Persistence follows SpaceRegistry / PlacedPropLayer:
##   user://maps/window_wall_viewpoint_<lat>_<lon>.json   (generated maps)
##   user://maps/window_wall_viewpoint_scene_<tag>.json   (built-in scenes)

const VERSION := 1

var pos := Vector3.ZERO
var yaw_deg := 0.0
var saved_at := ""


static func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/window_wall_viewpoint_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


static func save_path_for_scene(scene_key: String) -> String:
	var tag := scene_key.get_file().get_basename() if scene_key.contains("/") else scene_key
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/window_wall_viewpoint_scene_%s.json" % tag


## The file this Main's site keys to. A generated map is keyed by the loader's
## lat/lon; a built-in scene (no TerrainLoader) by its scene path.
static func path_for(main: Node) -> String:
	if main == null:
		return save_path_for_scene("")
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null:
		var lat: Variant = loader.get("_lat")
		var lon: Variant = loader.get("_lon")
		if lat is float and lon is float and not (is_zero_approx(lat) and is_zero_approx(lon)):
			return save_path_for_map(float(lat), float(lon))
	return save_path_for_scene(str(main.scene_file_path))


static func load_for(main: Node) -> WindowWallViewpoint:
	return load_from(path_for(main))


static func load_from(path: String) -> WindowWallViewpoint:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return null
	var vp := WindowWallViewpoint.new()
	if not vp.deserialize(parsed):
		return null
	return vp


static func delete_for(main: Node) -> void:
	var path := path_for(main)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("WindowWallViewpoint: cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(serialize(), "\t"))
	f.close()
	return true


func serialize() -> Dictionary:
	return {
		"version": VERSION,
		"pos": [pos.x, pos.y, pos.z],
		"yaw_deg": yaw_deg,
		"saved_at": saved_at,
	}


func deserialize(d: Dictionary) -> bool:
	var p: Variant = d.get("pos", null)
	if not (p is Array) or (p as Array).size() != 3:
		return false
	var arr := p as Array
	pos = Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if not pos.is_finite():
		return false
	yaw_deg = float(d.get("yaw_deg", 0.0))
	if not is_finite(yaw_deg):
		yaw_deg = 0.0
	saved_at = str(d.get("saved_at", ""))
	return true


## The eye for this viewpoint at the given seated eye height.
func eye(seat_eye_height_m: float) -> Vector3:
	return pos + Vector3(0.0, seat_eye_height_m, 0.0)


func describe() -> String:
	return "(%.1f, %.1f, %.1f) heading %.0f°" % [pos.x, pos.y, pos.z, fposmod(yaw_deg, 360.0)]

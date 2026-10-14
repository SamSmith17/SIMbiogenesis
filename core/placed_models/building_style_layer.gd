class_name BuildingStyleLayer
extends RefCounted

## Per-map, per-building style overrides keyed by the stable building tag
## (BuildingBuilder.building_tag — metre-rounded footprint centroid). A style
## record holds roof shape/pitch, wall/roof colors, height, base offset,
## facade elements (doors/windows), and `wall_mode` (int — a
## BuildingBuilder.WallMode value; absent or −1 = auto from tags/size).
## Buildings with a style are excluded from the merged OSM mesh and rebuilt
## individually by the terrain loader.

const VERSION := 1
const MAX_STYLES := 300


static func create_empty() -> BuildingStyleLayer:
	var layer := BuildingStyleLayer.new()
	layer.styles = {}
	return layer


## tag (String) -> style Dictionary. Colors are stored as [r, g, b, a] arrays
## (VegetationStyleConfig JSON convention) so records round-trip through JSON.
var styles: Dictionary = {}


func save_path_for_map(lat: float, lon: float) -> String:
	return WorldPaths.site_file("building_styles", lat, lon)


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


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
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	return {"version": VERSION, "styles": styles.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	styles = {}
	var raw: Variant = data.get("styles", {})
	if not (raw is Dictionary):
		return
	for tag in (raw as Dictionary):
		var style: Variant = (raw as Dictionary)[tag]
		if style is Dictionary:
			styles[str(tag)] = style


func has_style(tag: String) -> bool:
	return styles.has(tag)


func get_style(tag: String) -> Dictionary:
	var s: Variant = styles.get(tag, {})
	return (s as Dictionary).duplicate(true) if s is Dictionary else {}


## Stores a style; Color values are normalized to [r, g, b, a] arrays.
func set_style(tag: String, style: Dictionary) -> bool:
	if tag.is_empty():
		return false
	if not styles.has(tag) and styles.size() >= MAX_STYLES:
		return false
	var rec := style.duplicate(true)
	for key in ["wall_color", "roof_color"]:
		if rec.has(key) and rec[key] is Color:
			rec[key] = color_to_array(rec[key])
	rec["tag"] = tag
	styles[tag] = rec
	return true


func remove_style(tag: String) -> bool:
	return styles.erase(tag)


func all_tags() -> Array:
	return styles.keys()


static func color_to_array(c: Color) -> Array:
	return [c.r, c.g, c.b, c.a]


static func array_to_color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		var arr: Array = v
		var a := float(arr[3]) if arr.size() > 3 else 1.0
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), a)
	return fallback

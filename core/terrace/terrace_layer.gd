class_name TerraceLayer
extends RefCounted

## The terrace fields of one world: records (TerraceField) saved as one JSON
## file per site (WorldPaths kind "terraces"), plus whole-layer undo.
## Nothing else is saved: the cut, the paddies and the meshes are re-derived
## from the records and the ground.

const VERSION := 1
const UNDO_MAX := 30

var fields: Array = []
var path := ""
var _undo: Array = []
var _redo: Array = []
var _next := 1


static func path_for(lat: float, lon: float) -> String:
	return WorldPaths.site_file("terraces", lat, lon)


func load_from(p: String) -> void:
	path = p
	fields = []
	_next = 1
	_undo.clear()
	_redo.clear()
	if p.is_empty() or not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return
	for r in (data as Dictionary).get("fields", []):
		if r is Dictionary:
			fields.append(_from_json(r))
	_next = int((data as Dictionary).get("next", fields.size() + 1))


func save() -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var out: Array = []
	for r in fields:
		out.append(_to_json(r))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("TerraceLayer: cannot write %s" % path)
		return
	f.store_string(JSON.stringify({"version": VERSION, "next": _next, "fields": out}, "\t"))


## NAN does not survive JSON: the auto datum is stored as null.
static func _to_json(r: Dictionary) -> Dictionary:
	var d := r.duplicate(true)
	if d.has("datum") and (d["datum"] is float) and is_nan(float(d["datum"])):
		d["datum"] = null
	return d


static func _from_json(r: Dictionary) -> Dictionary:
	var d := r.duplicate(true)
	if not d.has("datum") or d["datum"] == null:
		d["datum"] = NAN
	return d


func checkpoint() -> void:
	_undo.append(fields.duplicate(true))
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()


func can_undo() -> bool:
	return not _undo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(fields.duplicate(true))
	fields = _undo.pop_back()
	save()
	return true


func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(fields.duplicate(true))
	fields = _redo.pop_back()
	save()
	return true


func find(id: String) -> Dictionary:
	for r in fields:
		if str((r as Dictionary).get("id", "")) == id:
			return r
	return {}


## A new field from an outline. Returns its record.
func add(poly: PackedVector2Array, settings: Dictionary = {}) -> Dictionary:
	var r := TerraceField.defaults()
	for k in settings.keys():
		r[k] = settings[k]
	r["id"] = "tf_%d" % _next
	if str(settings.get("name", "")).is_empty():
		r["name"] = "Terraces %d" % _next
	r["seed"] = _next
	_next += 1
	r["poly"] = TerraceField.poly_to_array(poly)
	fields.append(r)
	return r


func update(id: String, patch: Dictionary) -> bool:
	for i in fields.size():
		var r: Dictionary = fields[i]
		if str(r.get("id", "")) != id:
			continue
		for k in patch.keys():
			r[k] = patch[k]
		return true
	return false


func remove(id: String) -> bool:
	for i in fields.size():
		if str((fields[i] as Dictionary).get("id", "")) == id:
			fields.remove_at(i)
			return true
	return false


## The field whose outline holds p ("" = none).
func field_at(p: Vector2) -> String:
	for i in range(fields.size() - 1, -1, -1):
		var r: Dictionary = fields[i]
		var poly := TerraceField.poly_of(r)
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
			return str(r.get("id", ""))
	return ""


## A field an outline would overlap ("" = none).
func overlapping(poly: PackedVector2Array, except_id: String = "") -> String:
	for r in fields:
		var d: Dictionary = r
		if str(d.get("id", "")) == except_id:
			continue
		var other := TerraceField.poly_of(d)
		if other.size() < 3:
			continue
		if not Geometry2D.intersect_polygons(poly, other).is_empty():
			return str(d.get("id", ""))
	return ""

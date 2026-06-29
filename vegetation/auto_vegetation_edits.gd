class_name AutoVegetationEdits
extends RefCounted

## Per-map persisted edits to auto-populated vegetation (cleared zones, patches,
## user-painted forest zones). The generated AutoVegetationLayer is rebuilt from
## OSM on each load; these edits are replayed after generation.

const VERSION := 3

var cleared: Array = []  # Array[PackedVector2Array]
var patches: Array = []  # Array[Dictionary]
var forests: Array = []  # Array[Dictionary] user-painted forest zones


static func create_empty() -> AutoVegetationEdits:
	var edits := AutoVegetationEdits.new()
	edits.cleared = []
	edits.patches = []
	edits.forests = []
	return edits


static func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/auto_veg_edits_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


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


func add_cleared_polygon(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	cleared.append(poly.duplicate())


func add_patch(poly: PackedVector2Array, params: Dictionary) -> void:
	if poly.size() < 3 or params.is_empty():
		return
	patches.append({
		"polygon": poly.duplicate(),
		"params": params.duplicate(),
	})


func add_forest_zone(poly: PackedVector2Array, params: Dictionary) -> void:
	if poly.size() < 3:
		return
	forests.append({
		"polygon": poly.duplicate(),
		"profile": str(params.get("profile", "deciduous")),
		"canopy_height_m": float(params.get("canopy_height_m", 14.0)),
		"trunk_spacing_m": float(params.get("trunk_spacing_m", 10.0)),
		"seed": int(params.get("seed", _poly_seed(poly))),
		"source": "paint",
	})


func remove_forest_at_index(idx: int) -> void:
	if idx >= 0 and idx < forests.size():
		forests.remove_at(idx)


func apply_to_layer(layer: AutoVegetationLayer) -> void:
	if layer == null:
		return
	for poly in cleared:
		if poly is PackedVector2Array:
			layer.remove_in_polygon(poly as PackedVector2Array)
	for patch in patches:
		if patch is Dictionary:
			var poly: PackedVector2Array = patch.get("polygon", PackedVector2Array())
			var params: Dictionary = patch.get("params", {})
			if poly.size() >= 3:
				layer.apply_patch_in_polygon(poly, params)
	# Canopy-mesh "forest zones" were removed by request; legacy painted zones in
	# old save files are intentionally no longer replayed into the layer.


func serialize() -> Dictionary:
	var polys: Array = []
	for poly in cleared:
		if poly is PackedVector2Array:
			polys.append(_ser_points(poly as PackedVector2Array))
	var patch_arr: Array = []
	for patch in patches:
		if patch is Dictionary:
			var poly: PackedVector2Array = patch.get("polygon", PackedVector2Array())
			if poly.size() >= 3:
				patch_arr.append({
					"polygon": _ser_points(poly),
					"params": patch.get("params", {}),
				})
	var forest_arr: Array = []
	for fz in forests:
		if fz is Dictionary:
			var d: Dictionary = fz
			var poly: PackedVector2Array = d.get("polygon", PackedVector2Array())
			if poly.size() >= 3:
				forest_arr.append({
					"polygon": _ser_points(poly),
					"profile": str(d.get("profile", "deciduous")),
					"canopy_height_m": float(d.get("canopy_height_m", 14.0)),
					"trunk_spacing_m": float(d.get("trunk_spacing_m", 10.0)),
					"seed": int(d.get("seed", 0)),
					"source": str(d.get("source", "paint")),
				})
	return {"version": VERSION, "cleared": polys, "patches": patch_arr, "forests": forest_arr}


func deserialize(data: Dictionary) -> void:
	cleared = []
	patches = []
	forests = []
	for raw in data.get("cleared", []):
		var pts := _deser_points(raw)
		if pts.size() >= 3:
			cleared.append(pts)
	for raw in data.get("patches", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := _deser_points(d.get("polygon", []))
		var params: Variant = d.get("params", {})
		if pts.size() >= 3 and params is Dictionary:
			patches.append({"polygon": pts, "params": params})
	for raw in data.get("forests", []):
		if not (raw is Dictionary):
			continue
		var d: Dictionary = raw
		var pts := _deser_points(d.get("polygon", []))
		if pts.size() >= 3:
			forests.append({
				"polygon": pts,
				"profile": str(d.get("profile", "deciduous")),
				"canopy_height_m": float(d.get("canopy_height_m", 14.0)),
				"trunk_spacing_m": float(d.get("trunk_spacing_m", 10.0)),
				"seed": int(d.get("seed", _poly_seed(pts))),
				"source": str(d.get("source", "paint")),
			})


static func _poly_seed(poly: PackedVector2Array) -> int:
	var h := 0
	for p in poly:
		h = h ^ int(p.x * 100.0) ^ int(p.y * 100.0)
	return h


static func _ser_points(pts: PackedVector2Array) -> Array:
	var arr: Array = []
	for p in pts:
		arr.append([p.x, p.y])
	return arr


static func _deser_points(raw: Variant) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if raw is Array:
		for pair in raw:
			if pair is Array and (pair as Array).size() >= 2:
				pts.append(Vector2(float(pair[0]), float(pair[1])))
	return pts

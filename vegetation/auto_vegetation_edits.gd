class_name AutoVegetationEdits
extends RefCounted

## Per-map persisted edits to auto-populated vegetation (cleared zones, patches,
## per-area fills, user-painted forest zones). The generated AutoVegetationLayer
## is rebuilt from OSM on each load; these edits are replayed after generation.
##
## `cleared` and `patches` are SUBTRACTIVE/modifying: they are replayed over the
## finished layer. `fills` (VERSION 4) are ADDITIVE and instead run inside the
## generator as its last scatter phase, so a filled area is subject to the same
## budgets, exclusions and slope rules as any OSM polygon — and a clear drawn
## later still wins, because the subtractive pass runs after all scatter.

const VERSION := 4

var cleared: Array = []  # Array[PackedVector2Array]
var patches: Array = []  # Array[Dictionary]
var forests: Array = []  # Array[Dictionary] user-painted forest zones
## Array[Dictionary] — see add_fill(). Keyed by `tag` (the area's metre-rounded
## centroid, VegAreaPicker.area_info) so a fill survives an OSM re-fetch that
## renumbers the polygon list.
var fills: Array = []


static func create_empty() -> AutoVegetationEdits:
	var edits := AutoVegetationEdits.new()
	edits.cleared = []
	edits.patches = []
	edits.forests = []
	edits.fills = []
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


## Record (or replace) a per-area fill. One fill per `tag` — re-filling an area
## overwrites its previous settings rather than stacking a second forest into
## the same polygon.
func add_fill(tag: String, poly: PackedVector2Array, params: Dictionary) -> void:
	if tag.is_empty() or poly.size() < 3:
		return
	var entry := {
		"tag": tag,
		"polygon": poly.duplicate(),
		"species": str(params.get("species", "deciduous")),
		"density": clampf(float(params.get("density", 1.0)), 0.05, 4.0),
		"height_m": maxf(float(params.get("height_m", 0.0)), 0.0),
		"replace": bool(params.get("replace", true)),
		# Deterministic per fill, so a replay reproduces the same forest.
		"seed": int(params.get("seed", _poly_seed(poly))),
	}
	var at := fill_index_for_tag(tag)
	if at >= 0:
		fills[at] = entry
	else:
		fills.append(entry)
	# Filling an area that was previously cleared has to LIFT that clear: the
	# subtractive pass runs after all scatter, so an old clear over the same
	# outline would silently erase the forest the player just planted.
	_drop_cleared_matching(poly)


## Metre-rounded centroid id for a polygon — the same scheme
## VegAreaPicker.area_info uses, so a fill and a clear drawn over the same OSM
## area agree on identity across an OSM re-fetch.
static func centroid_tag(poly: PackedVector2Array) -> String:
	if poly.is_empty():
		return ""
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(poly.size())
	return "veg_%d_%d" % [roundi(c.x), roundi(c.y)]


func _drop_cleared_matching(poly: PackedVector2Array) -> void:
	var tag := centroid_tag(poly)
	var i := cleared.size() - 1
	while i >= 0:
		if cleared[i] is PackedVector2Array \
				and centroid_tag(cleared[i] as PackedVector2Array) == tag:
			cleared.remove_at(i)
		i -= 1


func fill_index_for_tag(tag: String) -> int:
	for i in fills.size():
		if fills[i] is Dictionary and str((fills[i] as Dictionary).get("tag", "")) == tag:
			return i
	return -1


func remove_fill_for_tag(tag: String) -> bool:
	var at := fill_index_for_tag(tag)
	if at < 0:
		return false
	fills.remove_at(at)
	return true


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
	# Every payload key needs a matching entry here AND in deserialize(): the
	# VegetationService cache once shipped `hedge_rows` in one direction only and
	# silently dropped every hedge on reload.
	var fill_arr: Array = []
	for fl in fills:
		if fl is Dictionary:
			var d: Dictionary = fl
			var poly: PackedVector2Array = d.get("polygon", PackedVector2Array())
			if poly.size() >= 3 and not str(d.get("tag", "")).is_empty():
				fill_arr.append({
					"tag": str(d.get("tag", "")),
					"polygon": _ser_points(poly),
					"species": str(d.get("species", "deciduous")),
					"density": float(d.get("density", 1.0)),
					"height_m": float(d.get("height_m", 0.0)),
					"replace": bool(d.get("replace", true)),
					"seed": int(d.get("seed", 0)),
				})
	return {"version": VERSION, "cleared": polys, "patches": patch_arr,
		"forests": forest_arr, "fills": fill_arr}


func deserialize(data: Dictionary) -> void:
	cleared = []
	patches = []
	forests = []
	# A v3 file simply has no `fills` key — nothing to migrate, the map just
	# opens with no per-area fills, which is what it had.
	fills = []
	for raw in data.get("fills", []):
		if not (raw is Dictionary):
			continue
		var fd: Dictionary = raw
		var fpts := _deser_points(fd.get("polygon", []))
		var tag := str(fd.get("tag", ""))
		if fpts.size() >= 3 and not tag.is_empty():
			fills.append({
				"tag": tag,
				"polygon": fpts,
				"species": str(fd.get("species", "deciduous")),
				"density": clampf(float(fd.get("density", 1.0)), 0.05, 4.0),
				"height_m": maxf(float(fd.get("height_m", 0.0)), 0.0),
				"replace": bool(fd.get("replace", true)),
				"seed": int(fd.get("seed", _poly_seed(fpts))),
			})
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

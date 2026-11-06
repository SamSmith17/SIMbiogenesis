class_name WorldLauncher
extends RefCounted

## The one way a screen turns a place into a playing world, shared by the 2D
## location picker and the Globe mode: register the MAP (MapRegistry, one
## loc_<lat>_<lon>.tres per site), create the WORLD (WorldStore), save the
## world that is running if any, then WorldSession.launch.


## The MAP registry entry for a site. prefer_label: this selection has a real
## place name, so it may replace the site's old one.
static func register_map(lat: float, lon: float, label: String, prefer_label: bool) -> Dictionary:
	return MapRegistry.ensure_generated({"lat": lat, "lon": lon, "label": label}, prefer_label)


static func find_main(tree: SceneTree) -> Node:
	if tree == null:
		return null
	var cur := tree.current_scene
	if cur != null and str(cur.name) == "Main":
		return cur
	return tree.root.find_child("Main", true, false)


## In-game, the running world is saved before switching.
static func save_running_world(tree: SceneTree) -> void:
	var main := find_main(tree)
	if main != null and WorldPaths.has_active_world():
		WorldSession.save_now(main, true, true)


## A new world on a generated map at lat/lon, launched.
static func create_world_at(tree: SceneTree, lat: float, lon: float, label: String,
		world_name: String = "", opts: Dictionary = {}, prefer_label: bool = true) -> Error:
	var map := register_map(lat, lon, label, prefer_label)
	var rec := WorldStore.create(map, world_name)
	return play(tree, rec, opts)


static func play(tree: SceneTree, rec: Dictionary, opts: Dictionary = {}) -> Error:
	save_running_world(tree)
	return WorldSession.launch(rec, opts)


## [lat, lon] of a world record's map, or empty when it has none (a built-in
## scene with no coordinates).
static func world_latlon(rec: Dictionary) -> PackedFloat64Array:
	var map: Variant = rec.get("map", {})
	if not (map is Dictionary):
		return PackedFloat64Array()
	var m: Dictionary = map
	if not m.has("lat") or not m.has("lon"):
		return PackedFloat64Array()
	var la := float(m["lat"])
	var lo := float(m["lon"])
	if is_nan(la) or is_nan(lo) or (la == 0.0 and lo == 0.0):
		return PackedFloat64Array()
	return PackedFloat64Array([la, lo])

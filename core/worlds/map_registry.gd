class_name MapRegistry
extends RefCounted

## The MAP registry: one user://maps/loc_<lat>_<lon>.tres per generated site
## (label + extents), shared by every world on it. Used by the location
## picker when a site is chosen and by asset-pack import, which rebuilds the
## entry from the world's own map dict — a .tres is never taken from a pack
## (a text resource can carry a script).


## Make sure the site's definition exists and return the world's map ref for
## it. Re-registering a site keeps its existing name unless `prefer_label`
## (a fresh pick with a real place name), and never resets its extents or
## OSM offsets. `map` needs lat, lon, label; extents are optional.
static func ensure_generated(map: Dictionary, prefer_label: bool = false,
		maps_dir: String = "user://maps") -> Dictionary:
	var lat := float(map["lat"])
	var lon := float(map["lon"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(maps_dir))
	var path := "%s/loc_%s_%s.tres" % [maps_dir, CoordToken.token(lat), CoordToken.token(lon)]
	var md: MapDefinition = null
	if ResourceLoader.exists(path):
		md = load(path) as MapDefinition
	if md == null:
		md = MapDefinition.new()
		md.scene_path = MapDefinition.GENERATED_SCENE
		md.latitude = lat
		md.longitude = lon
	if prefer_label or md.display_name.is_empty() or md.display_name == "Map":
		md.display_name = str(map.get("label", "Map"))
	md.description = "Location map for %s.\nTerrain + imagery from open data." % md.display_name
	md.load_from_cache = true
	md.touch_last_loaded()
	var meta := TerrainCacheSettings.get_meta_extents(lat, lon)
	for k in ["half_extent_m", "detail_half_extent_m", "osm_half_extent_m"]:
		if float(md.get(k)) <= 0.0:
			var v := float(map.get(k, 0.0))
			md.set(k, v if v > 0.0 else float(meta.get(k, 0.0)))
	if ResourceSaver.save(md, path) != OK:
		push_warning("MapRegistry: could not write %s" % path)
	return WorldStore.map_ref_from_definition(md, path)

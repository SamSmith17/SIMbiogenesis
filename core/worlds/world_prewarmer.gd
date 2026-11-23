class_name WorldPrewarmer
extends RefCounted

## Background world prewarmer + pure Globe↔World camera alignment math.
##
## Started the moment the player initiates a world launch from GlobeMode:
##   1. Requests `ResourceLoader.load_threaded_request` on the playable scene
##      (`generated_location.tscn`) so script compilation, sub-scenes and
##      resources load on background threads while the Globe flies in at 60 fps.
##   2. Pre-warms cached DEM grids (base + detail), cached imagery drapes
##      (base + detail, decoded + mipmapped + S3TC/BC7 compressed), and cached
##      OSM vectors + vegetation on `WorkerThreadPool` so `TerrainLoader` finds
##      them ready in memory instead of stalling sequentially after scene load.
##   3. Resolves the exact arrival target (saved player XZ → lat/lon, compass
##      heading matching player yaw, and saved `CelestialClock` UTC Julian Day)
##      and maps any Globe camera frame `(lat, lon, cam_range, heading, tilt)`
##      onto the exact local tangent 3D camera pose in `Main`.

const EARTH_RADIUS_M := 6371000.0
const GLOBE_FOV_DEG := 40.0
const TERRAIN_CFG_PATH := "user://terrain_config.cfg"


## Resolve the playable `.tscn` path for a world record, or `""` if untrusted.
static func playable_scene_for(rec: Dictionary) -> String:
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var scene := MapDefinition.normalize_scene_path(str(map.get("scene_path", "")))
	if not MapDefinition.is_trusted_scene_path(scene):
		return ""
	return MapDefinition.resolve_playable_scene_path(scene)


## Resolve the exact site extents (`world_half_m`, `detail_half_m`, `osm_half_m`)
## `WorldSession.launch` + `TerrainLoader._resolve_location` will build for `rec`.
static func resolve_extents(rec: Dictionary, snap: Dictionary) -> Dictionary:
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var lat := float(map.get("lat", 0.0))
	var lon := float(map.get("lon", 0.0))
	var he := float(map.get("half_extent_m", 0.0))
	var dhe := float(map.get("detail_half_extent_m", 0.0))
	var ohe := float(map.get("osm_half_extent_m", 0.0))
	if not snap.is_empty():
		if float(snap.get("half_extent_m", 0.0)) > 0.0:
			he = float(snap["half_extent_m"])
		if float(snap.get("detail_half_extent_m", 0.0)) > 0.0:
			dhe = float(snap["detail_half_extent_m"])
		if float(snap.get("osm_half_extent_m", 0.0)) > 0.0:
			ohe = float(snap["osm_half_extent_m"])
	var meta := TerrainCacheSettings.get_meta_extents(lat, lon)
	var cfg := ConfigFile.new()
	var has_cfg := FileAccess.file_exists(TERRAIN_CFG_PATH) and cfg.load(TERRAIN_CFG_PATH) == OK
	if he <= 0.0:
		he = float(meta.get("half_extent_m", 0.0))
		if he <= 0.0 and has_cfg:
			he = float(cfg.get_value("terrain", "world_half_extent_m", 0.0))
		if he <= 0.0:
			he = TerrainExtents.WORLD_HALF_DEFAULT
	if dhe <= 0.0:
		dhe = float(meta.get("detail_half_extent_m", 0.0))
		if dhe <= 0.0 and has_cfg:
			dhe = float(cfg.get_value("terrain", "detail_half_extent_m", 0.0))
		if dhe <= 0.0:
			dhe = TerrainExtents.DETAIL_HALF_DEFAULT
	if ohe <= 0.0:
		ohe = float(meta.get("osm_half_extent_m", 0.0))
		if ohe <= 0.0 and has_cfg:
			ohe = float(cfg.get_value("terrain", "osm_half_extent_m", 0.0))
		if ohe <= 0.0:
			ohe = TerrainExtents.OSM_HALF_DEFAULT
	return TerrainExtents.sanitize(he, dhe, ohe)


## Kick off threaded scene load + parallel worker prewarming of terrain caches.
## Returns the playable scene path started (or `""`).
static func begin(tree: SceneTree, rec: Dictionary, snap: Dictionary = {},
		opts: Dictionary = {}) -> String:
	var scene_file := playable_scene_for(rec)
	if scene_file.is_empty():
		return ""
	if ResourceLoader.exists(scene_file):
		ResourceLoader.load_threaded_request(scene_file, "PackedScene")
	if tree == null or bool(opts.get("force_refetch", false)):
		return scene_file
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var norm_scene := MapDefinition.normalize_scene_path(str(map.get("scene_path", "")))
	if norm_scene != MapDefinition.GENERATED_SCENE:
		return scene_file
	var ll := WorldLauncher.world_latlon(rec)
	if ll.size() != 2 or not TerrainCacheSettings.cache_enabled():
		return scene_file
	var lat := ll[0]
	var lon := ll[1]
	var ext := resolve_extents(rec, snap)
	var world_half := float(ext["world_half_m"])
	var detail_half := float(ext["detail_half_m"])
	var osm_half := float(ext["osm_half_m"])

	var es := tree.root.get_node_or_null("ElevationService")
	if es != null and es.has_method("prewarm_elevation"):
		es.call("prewarm_elevation", lat, lon, world_half,
			es.call("base_grid_n_for_extent", world_half), "base")
		es.call("prewarm_elevation", lat, lon, detail_half, 512, "detail")

	var img := tree.root.get_node_or_null("ImageryService")
	if img != null and img.has_method("prewarm_imagery"):
		var side_km := world_half * 2.0 / 1000.0
		var base_px := clampi(int(side_km * 32.0), 2048, 8192)
		img.call("prewarm_imagery", lat, lon, world_half, base_px, "base", 17, [], false)
		var ti := WorldSession.imagery_record(rec, snap)
		var local_tier := TerrainImageryPlan.local_tier()
		var saved_tier := clampi(int(ti.get("saved_tier", -1)), -1, TerrainImageryPlan.TIER_COUNT - 1)
		var mode := "saved" if str(ti.get("mode", "local")) == "saved" and saved_tier >= 0 else "local"
		var sharp := ImagerySources.sharp_preference(ti.get("sharp", ""))
		var ov := TerrainImageryPlan.with_sharp(TerrainImageryPlan.config_overrides(), sharp)
		var detail_tier := local_tier
		if mode == "saved" and saved_tier >= 0 and saved_tier != local_tier:
			var dl := TerrainImageryPlan.layer("detail", saved_tier, lat, lon, detail_half, ov)
			if dl.is_empty() or TerrainImageryPlan.is_cached(dl):
				detail_tier = saved_tier
		var detail_px := int(TerrainImageryPlan.DETAIL_TARGET_PX[detail_tier])
		img.call("prewarm_imagery", lat, lon, detail_half, detail_px, "detail", 19, [], false)
		for tag_name in ["hyper", "site"]:
			var tag_tier := local_tier
			if mode == "saved" and saved_tier >= 0 and saved_tier != local_tier:
				var cand_l := TerrainImageryPlan.layer(tag_name, saved_tier, lat, lon, detail_half, ov)
				if cand_l.is_empty() or TerrainImageryPlan.is_cached(cand_l):
					tag_tier = saved_tier
			var lp := TerrainImageryPlan.layer(tag_name, tag_tier, lat, lon, detail_half, ov)
			if not lp.is_empty():
				img.call("prewarm_imagery", lat, lon, float(lp["half"]),
					int(lp["px"]), tag_name, int(lp["max_zoom"]),
					lp.get("chain", []) as Array, bool(lp.get("hq", false)))

	var cfg := ConfigFile.new()
	var flatten_lu := false
	var show_auto_veg := true
	if FileAccess.file_exists(TERRAIN_CFG_PATH) and cfg.load(TERRAIN_CFG_PATH) == OK:
		flatten_lu = bool(cfg.get_value("terrain", "flatten_landuse", false))
		show_auto_veg = bool(cfg.get_value("terrain", "show_auto_vegetation", true))

	var bs := tree.root.get_node_or_null("BuildingService")
	if bs != null and bs.has_method("prewarm_osm_vectors"):
		bs.call("prewarm_osm_vectors", lat, lon, osm_half, flatten_lu)

	if show_auto_veg:
		var vs := tree.root.get_node_or_null("VegetationService")
		if vs != null and vs.has_method("prewarm_vegetation"):
			vs.call("prewarm_vegetation", lat, lon, osm_half)

	return scene_file


## Poll threaded scene load status (`{ready: bool, progress: float, packed: PackedScene}`).
static func poll_scene(scene_file: String) -> Dictionary:
	if scene_file.is_empty():
		return {"ready": false, "progress": 0.0, "packed": null}
	var prog := []
	var st := ResourceLoader.load_threaded_get_status(scene_file, prog)
	var p := float(prog[0]) if not prog.is_empty() else 0.0
	if st == ResourceLoader.THREAD_LOAD_LOADED:
		var res := ResourceLoader.load_threaded_get(scene_file)
		return {"ready": true, "progress": 1.0, "packed": res as PackedScene}
	if st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		var fallback := load(scene_file) as PackedScene
		return {"ready": true, "progress": 1.0, "packed": fallback}
	return {"ready": false, "progress": clampf(p, 0.0, 0.99), "packed": null}


## Pure camera/lighting target for launching `rec` with saved snapshot `snap`:
##   - `lat`, `lon`: exact WGS84 point where the player stands (saved XZ, else
##     map centre), so the Globe flies onto the player's actual spot on the map.
##   - `heading_deg`: compass heading in GlobeView convention (0° = North/-Z,
##     90° = East/+X) matching the saved player yaw, or NAN when starting fresh.
##   - `jd_utc`: Julian Day UTC of the saved `CelestialClock`, or NAN when fresh.
static func launch_camera_target(rec: Dictionary, snap: Dictionary = {}) -> Dictionary:
	var ll := WorldLauncher.world_latlon(rec)
	if ll.size() != 2:
		return {}
	var map_lat := ll[0]
	var map_lon := ll[1]
	var target_lat := map_lat
	var target_lon := map_lon
	var local_xz := Vector2.ZERO
	var heading_deg := NAN
	var jd_utc := NAN

	var ext := resolve_extents(rec, snap)
	var limit := maxf(float(ext["world_half_m"]) - 50.0, 0.0)

	if not snap.is_empty():
		var pd: Variant = snap.get("player", {})
		if pd is Dictionary:
			var pdict: Dictionary = pd
			var pos_v: Variant = pdict.get("position", {})
			if pos_v is Dictionary and not (pos_v as Dictionary).is_empty():
				var pos := SaveSerialization.dict_to_vec3(pos_v as Dictionary)
				var px := clampf(pos.x, -limit, limit)
				var pz := clampf(pos.z, -limit, limit)
				if is_finite(px) and is_finite(pz):
					local_xz = Vector2(px, pz)
					# 64-bit float arithmetic (Vector2 is float32 and rounds a
					# longitude by ~0.5 m).
					var mpd := GeoMath.meters_per_deg(map_lat)
					target_lon = map_lon + px / maxf(float(mpd.x), 1.0)
					target_lat = map_lat - pz / maxf(float(mpd.y), 1.0)
			var rot_v: Variant = pdict.get("rotation", {})
			if rot_v is Dictionary and not (rot_v as Dictionary).is_empty():
				var rot := SaveSerialization.dict_to_vec3(rot_v as Dictionary)
				var yaw := rot.y
				if is_finite(yaw):
					heading_deg = fposmod(-rad_to_deg(yaw), 360.0)
		var md: Variant = snap.get("main", {})
		if md is Dictionary and not (md as Dictionary).is_empty():
			var mdict: Dictionary = md
			var clk := CelestialClock.new()
			clk.latitude = float(mdict.get("latitude", map_lat))
			clk.longitude = float(mdict.get("longitude", map_lon))
			clk.auto_dst = bool(mdict.get("auto_dst", true))
			clk.manual_dst = bool(mdict.get("manual_dst", false))
			clk.year = int(mdict.get("year", 2026))
			clk.month = int(mdict.get("month", 6))
			clk.day = int(mdict.get("day", 21))
			clk.day_time = float(mdict.get("day_time", 12.0))
			jd_utc = clk.get_julian_day_utc()

	return {
		"map_lat": map_lat,
		"map_lon": map_lon,
		"lat": target_lat,
		"lon": target_lon,
		"local_xz": local_xz,
		"heading_deg": heading_deg,
		"has_heading": is_finite(heading_deg),
		"jd_utc": jd_utc,
		"has_jd": is_finite(jd_utc),
	}


## Local tangent isomorphism of `GlobeView._cam_frame()`: maps a Globe camera
## state `(target_lat, target_lon, cam_range, cam_heading_deg, cam_tilt_deg)`
## into `Main`'s 3D world space `(X = East, -Z = North, +Y = Up)` centred on
## `(map_lat, map_lon)` with terrain height `ground_y` at the target point.
static func local_pose_for_globe_camera(target_lat: float, target_lon: float,
		cam_range: float, cam_heading_deg: float, cam_tilt_deg: float,
		map_lat: float, map_lon: float, ground_y: float = 0.0) -> Dictionary:
	var xz := GeoMath.lonlat_to_local_m(target_lat, target_lon, map_lat, map_lon)
	var look := Vector3(xz.x, ground_y, xz.y)
	var h := deg_to_rad(cam_heading_deg)
	var t := deg_to_rad(clampf(cam_tilt_deg, 0.0, 88.0))
	var hv := Vector3(sin(h), 0.0, -cos(h)).normalized()
	var up_axis := Vector3.UP
	var back := up_axis * cos(t) - hv * sin(t)
	var dist_m := maxf(cam_range * EARTH_RADIUS_M, 2.0)
	var pos := look + back * dist_m
	var cam_up := (hv * cos(t) + up_axis * sin(t)).normalized()
	var xf := Transform3D(Basis.looking_at(look - pos, cam_up), pos)
	return {
		"transform": xf,
		"pos": pos,
		"look": look,
		"up": cam_up,
		"dist_m": dist_m,
		"fov": GLOBE_FOV_DEG,
	}

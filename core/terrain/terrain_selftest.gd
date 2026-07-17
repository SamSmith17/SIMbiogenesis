extends SceneTree

## Headless self-test for the location→world terrain math (GeoMath +
## TerrainBuilder). Pure / offline — no network.
## Run with:
##   godot --headless --path . --script core/terrain/terrain_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const ElevationServiceScript := preload("res://core/terrain/elevation_service.gd")
const BuildingServiceScript := preload("res://core/terrain/building_service.gd")
const ImageryServiceScript := preload("res://core/terrain/imagery_service.gd")
const OsmRegistrationScript := preload("res://core/terrain/osm_registration.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_hyperbolic()
	_test_metric()
	_test_tiles()
	_test_resample()
	_test_local_metric()
	_test_buildings()
	_test_solar_array()
	_test_mesh()
	_test_terrain_node()
	_test_coarse_hide()
	_test_seam_compose()
	_test_aaigrid()
	_test_aaigrid_georef()
	_test_dem_extent_recovery()
	_test_imagery_equirect_warp()
	_test_osm_registration()
	_test_dem_usability()
	_test_base_grid_extent()
	_test_cache_settings()
	_test_load_progress()
	_test_sculpt_ops()
	if _failures == 0:
		print("TERRAIN SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("TERRAIN SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _test_solar_array() -> void:
	_check("solar tilt mid-lat", _approx(SolarArrayBuilder.default_tilt_deg(42.43), 35.4, 0.5),
		"got %f" % SolarArrayBuilder.default_tilt_deg(42.43))
	_check("solar azimuth N hemi", SolarArrayBuilder.default_azimuth_deg(42.0) == 180.0)
	_check("solar azimuth S hemi", SolarArrayBuilder.default_azimuth_deg(-33.0) == 0.0)

	var sq := PackedVector2Array([Vector2(-6, -6), Vector2(6, -6), Vector2(6, 6), Vector2(-6, 6)])
	var panels := SolarArrayBuilder.plan_panels(sq, 35.0)
	_check("solar packing positive", panels.size() > 10, "got %d" % panels.size())
	_check("solar packing bounded", panels.size() < 200, "got %d" % panels.size())
	var all_in := true
	for rec in panels:
		if not Geometry2D.is_point_in_polygon(Vector2(float(rec["x"]), float(rec["z"])), sq):
			all_in = false
	_check("solar panels inside footprint", all_in)

	# Larger modules → fewer panels that fit the same footprint.
	var big_spec := SolarArrayBuilder.resolve_panel_spec({"panel_w_m": 2.1, "panel_h_m": 3.5})
	var fewer := SolarArrayBuilder.plan_panels(sq, 35.0, big_spec)
	_check("solar larger panels fit fewer", fewer.size() < panels.size(),
		"default=%d big=%d" % [panels.size(), fewer.size()])
	_check("solar count_panels matches plan",
		SolarArrayBuilder.count_panels_for_footprint(sq, 35.0) == panels.size())

	var sm := SolarArrayBuilder.summarize(30)
	_check("solar capacity 30x400W=12kW", _approx(float(sm["capacity_kw"]), 12.0, 0.001),
		"got %f" % float(sm["capacity_kw"]))

	var node := SolarArrayBuilder.build_array_node("Test", panels, 5.0, 35.0)
	var mmi := node.get_node_or_null("Panels") as MultiMeshInstance3D
	_check("solar node has MultiMesh", mmi != null and mmi.multimesh != null)
	if mmi != null and mmi.multimesh != null:
		_check("solar instance count matches placement",
			mmi.multimesh.instance_count == panels.size(),
			"mm=%d panels=%d" % [mmi.multimesh.instance_count, panels.size()])
	node.free()

	# Mount styles: ground has posts + taller rack; flat uses shallow tilt.
	_check("mount resolve ground",
		SolarArrayBuilder.resolve_mount_style("ground") == SolarArrayBuilder.MOUNT_GROUND)
	_check("mount infer roof",
		SolarArrayBuilder.infer_mount_style({"location": "roof"}) == SolarArrayBuilder.MOUNT_ROOF)
	var gdefs := SolarArrayBuilder.mount_defaults(SolarArrayBuilder.MOUNT_GROUND, 35.0)
	var fdefs := SolarArrayBuilder.mount_defaults(SolarArrayBuilder.MOUNT_FLAT, 35.0)
	_check("ground rack taller than flat",
		float(gdefs["rack_height_m"]) > float(fdefs["rack_height_m"]))
	_check("flat tilt shallow", float(fdefs["tilt_deg"]) <= 10.0)
	var gnode := SolarArrayBuilder.build_array_node(
		"Ground", panels, 5.0, float(gdefs["tilt_deg"]), {}, SolarArrayBuilder.MOUNT_GROUND)
	_check("ground mount has posts", gnode.get_node_or_null("RackPosts") != null)
	gnode.free()
	var rack := PalletRackBuilder.build_node({"bay_count": 2, "levels": 2})
	_check("pallet rack builds children", rack.get_child_count() > 0)
	rack.free()

	var c := SolarArrayBuilder.centroid(sq)
	_check("solar centroid at origin", c.length() < 0.001)

	_check("solar tag detect source",
		BuildingServiceScript.is_solar_generator_tags({"generator:source": "solar"}))
	_check("solar tag detect method",
		BuildingServiceScript.is_solar_generator_tags({"generator:method": "photovoltaic"}))
	_check("solar tag rejects building",
		not BuildingServiceScript.is_solar_generator_tags({"building": "yes"}))

	var raw := {"solar": [{"points": [[-6, -6], [6, -6], [6, 6], [-6, 6]],
		"tags": {"power": "generator"}, "area_m2": 144.0}]}
	var de := BuildingServiceScript.deserialize_payload(raw)
	_check("solar payload round-trips", (de.get("solar", []) as Array).size() == 1,
		"got %d" % (de.get("solar", []) as Array).size())


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _test_hyperbolic() -> void:
	_check("sinh(0)==0", _approx(GeoMath.sinh(0.0), 0.0, 1e-9))
	_check("asinh(sinh(x)) round-trip", _approx(GeoMath.asinh(GeoMath.sinh(1.3)), 1.3, 1e-6))
	_check("sinh odd", _approx(GeoMath.sinh(-0.7), -GeoMath.sinh(0.7), 1e-9))


func _test_metric() -> void:
	# Latitude metric ~constant; longitude metric shrinks with cos(lat).
	var eq := GeoMath.meters_per_deg(0.0)
	_check("m/deg lon at equator ~111320", _approx(eq.x, 111320.0, 1.0), "got %.1f" % eq.x)
	var hi := GeoMath.meters_per_deg(60.0)
	_check("m/deg lon at 60N ~half", _approx(hi.x, 111320.0 * 0.5, 50.0), "got %.1f" % hi.x)
	_check("m/deg lat constant", _approx(hi.y, eq.y, 0.001))

	# A 30 km square (half-extent 15 km) about Seattle.
	var bbox := GeoMath.bbox_for(47.6062, -122.3321, 15000.0)
	var dlat: float = float(bbox["north"]) - float(bbox["south"])
	var span_m := dlat * GeoMath.M_PER_DEG_LAT
	_check("bbox N-S spans ~30 km", _approx(span_m, 30000.0, 100.0), "got %.0f m" % span_m)
	_check("bbox ordered N>S", float(bbox["north"]) > float(bbox["south"]))
	_check("bbox ordered E>W", float(bbox["east"]) > float(bbox["west"]))


func _test_tiles() -> void:
	# Round-trip a known location through tile space at several zooms.
	for z in [4, 10, 15]:
		var lon := -122.3321
		var lat := 47.6062
		var tf := GeoMath.lonlat_to_tile_f(lon, lat, z)
		var back := GeoMath.tile_to_lonlat(tf.x, tf.y, z)
		_check("tile lon round-trip z=%d" % z, _approx(back.x, lon, 1e-4),
			"got %.5f" % back.x)
		_check("tile lat round-trip z=%d" % z, _approx(back.y, lat, 1e-4),
			"got %.5f" % back.y)

	# Tile x grows east, y grows south.
	var t_w := GeoMath.lonlat_to_tile(-100.0, 40.0, 8)
	var t_e := GeoMath.lonlat_to_tile(-90.0, 40.0, 8)
	_check("tile x grows east", t_e.x > t_w.x)
	var t_n := GeoMath.lonlat_to_tile(-100.0, 50.0, 8)
	var t_s := GeoMath.lonlat_to_tile(-100.0, 30.0, 8)
	_check("tile y grows south", t_s.y > t_n.y)

	# Range + zoom selection for a 30 km bbox.
	var bbox := GeoMath.bbox_for(47.6062, -122.3321, 15000.0)
	var z2 := GeoMath.pick_zoom(bbox, 2048)
	_check("pick_zoom in range", z2 >= 8 and z2 <= 17, "got %d" % z2)
	var rng := GeoMath.tile_range_for_bbox(bbox, z2)
	_check("tile range x ordered", int(rng["max_x"]) >= int(rng["min_x"]))
	_check("tile range y ordered", int(rng["max_y"]) >= int(rng["min_y"]))
	var across := int(rng["max_x"]) - int(rng["min_x"]) + 1
	_check("tile range stitches <= ~2048px", across * 256 <= 2048 + 512,
		"%d tiles across" % across)


func _test_resample() -> void:
	# 2×2 source ramp 0,1 / 2,3 → corners preserved, centre is the average.
	var src := PackedFloat32Array([0.0, 1.0, 2.0, 3.0])
	_check("bilinear corner NW", _approx(TerrainBuilder.sample_bilinear(src, 2, 2, 0, 0), 0.0, 1e-6))
	_check("bilinear corner SE", _approx(TerrainBuilder.sample_bilinear(src, 2, 2, 1, 1), 3.0, 1e-6))
	_check("bilinear centre avg", _approx(TerrainBuilder.sample_bilinear(src, 2, 2, 0.5, 0.5), 1.5, 1e-6))

	# NAN corner is filled from finite neighbours rather than poisoning output.
	var holed := PackedFloat32Array([NAN, 10.0, 10.0, 10.0])
	var s := TerrainBuilder.sample_bilinear(holed, 2, 2, 0.5, 0.5)
	_check("bilinear ignores NAN", not is_nan(s) and s > 0.0, "got %f" % s)

	var up := TerrainBuilder.resample(src, 2, 2, 5)
	_check("resample size", up.size() == 25)
	_check("resample keeps NW corner", _approx(up[0], 0.0, 1e-6))
	_check("resample keeps SE corner", _approx(up[24], 3.0, 1e-6))

	_check("mean_elevation", _approx(TerrainBuilder.mean_elevation(src), 1.5, 1e-6))
	_check("mean_elevation skips NAN",
		_approx(TerrainBuilder.mean_elevation(PackedFloat32Array([NAN, 2.0, 4.0])), 3.0, 1e-6))
	_check("variant_to_float null safe", _approx(TerrainBuilder.variant_to_float(null, 5.0), 5.0, 1e-6))

	# Flat tile at 500 m AMSL → world y is 0 everywhere after mean-centring.
	var flat := PackedFloat32Array()
	flat.resize(9)
	flat.fill(500.0)
	_check("height_at_world flat tile", _approx(
		TerrainBuilder.height_at_world_xz(flat, 3, 30000.0, 500.0, 0.0, 0.0), 0.0, 1e-6))
	# Single centre spike: mean-centring leaves map centre well above y=0.
	var spike := PackedFloat32Array()
	spike.resize(9)
	spike.fill(0.0)
	spike[4] = 1000.0
	var spike_center := TerrainBuilder.mean_elevation(spike)
	var spike_y := TerrainBuilder.height_at_world_xz(spike, 3, 30000.0, spike_center, 0.0, 0.0)
	_check("height_at_world centre spike above mean", spike_y > 100.0, "got %.1f" % spike_y)


func _test_local_metric() -> void:
	var lat := 47.6062
	var lon := -122.3321
	var local := GeoMath.lonlat_to_local_m(lat, lon, lat, lon)
	_check("local origin is 0,0", _approx(local.x, 0.0, 1e-6) and _approx(local.y, 0.0, 1e-6))
	var east := GeoMath.lonlat_to_local_m(lat, lon + 0.001, lat, lon)
	_check("local +X is east", east.x > 50.0 and absf(east.y) < 5.0, "got %s" % str(east))
	var back := GeoMath.local_m_to_lonlat(east.x, east.y, lat, lon)
	_check("local round-trip lon", _approx(back.x, lon + 0.001, 1e-4))
	_check("local round-trip lat", _approx(back.y, lat, 1e-4))


func _test_buildings() -> void:
	_check("height tag metres", _approx(BuildingBuilder.parse_height_m({"height": "12"}), 12.0, 1e-6))
	_check("height tag with m suffix", _approx(BuildingBuilder.parse_height_m({"height": "8 m"}), 8.0, 1e-6))
	_check("height tag feet", _approx(BuildingBuilder.parse_height_m({"height": "30 ft"}), 30.0 * 0.3048, 1e-3))
	_check("levels default", _approx(BuildingBuilder.parse_height_m({"building:levels": "4"}), 11.2, 1e-6))
	_check("default height", _approx(BuildingBuilder.parse_height_m({}), BuildingBuilder.DEFAULT_HEIGHT_M, 1e-6))

	var sample := {
		"elements": [
			{"type": "node", "id": 1, "lat": 47.6062, "lon": -122.3321},
			{"type": "node", "id": 2, "lat": 47.6062, "lon": -122.3311},
			{"type": "node", "id": 3, "lat": 47.6052, "lon": -122.3311},
			{"type": "node", "id": 4, "lat": 47.6052, "lon": -122.3321},
			{"type": "way", "id": 10, "nodes": [1, 2, 3, 4, 1],
				"tags": {"building": "yes", "height": "15"}},
		],
	}
	var parsed: Dictionary = BuildingServiceScript._parse_overpass(sample, 47.6060, -122.3320, false)
	var buildings: Array = parsed.get("buildings", [])
	_check("overpass parse one building", buildings.size() == 1)
	if not buildings.is_empty():
		var pts: PackedVector2Array = buildings[0]["points"]
		_check("footprint has 5 pts (closed)", pts.size() == 5)
		_check("footprint height", _approx(float(buildings[0]["height_m"]), 15.0, 1e-6))

	var roof := BuildingBuilder.parse_roof_spec({"roof:shape": "gabled", "roof:angle": "35"})
	_check("roof shape parsed", str(roof.get("shape")) == "gabled")
	_check("roof angle parsed", _approx(float(roof.get("angle_deg")), 35.0, 1e-6))
	var oblong := PackedVector2Array([
		Vector2(-30, -8), Vector2(30, -8), Vector2(30, 8), Vector2(-30, 8),
	])
	var inferred: Dictionary = BuildingBuilder.infer_roof_spec({}, oblong)
	_check("inferred flat for oblong without roof tags", str(inferred.get("shape")) == "flat")

	_check("highway half width residential",
		_approx(TerrainRoadFlatten.highway_half_width({"highway": "residential"}), 4.0, 1e-6))
	var road_pts := PackedVector2Array([Vector2(-120, 0), Vector2(120, 0)])
	var slope := PackedFloat32Array([0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0])
	var roads := [{"points": road_pts, "half_width_m": 40.0}]
	var flat_roads := TerrainRoadFlatten.apply_road_corridors(slope, 3, 300.0, roads, 0.0)
	_check("road flatten preserves grid size", flat_roads.size() == slope.size())
	var coarse_roads := TerrainRoadFlatten.apply_road_corridors(slope, 3, 30000.0, roads, 0.0)
	_check("road flatten skips coarse grid", coarse_roads == slope)

	var base := PackedFloat32Array()
	base.resize(25)
	base.fill(100.0)
	var detail := PackedFloat32Array()
	detail.resize(25)
	for i in 25:
		detail[i] = 120.0
	var patched := TerrainBuilder.patch_centre_heights(base, 5, detail, 5, 1000.0, 400.0, 0.0)
	_check("detail patch raises centre", patched[12] > 100.0, "got %.1f" % patched[12])
	_check("detail patch leaves corner", _approx(patched[0], 100.0, 1e-6))
	var sunk := patched.duplicate()
	TerrainBuilder.sink_coarse_centre_for_detail(sunk, 5, 1000.0, 400.0, 100.0)
	_check("sink lowers centre for detail collision", sunk[12] < patched[12],
		"sunk=%.1f patched=%.1f" % [sunk[12], patched[12]])
	var detail_foot := detail.duplicate()
	var sunk_y := TerrainBuilder.height_at_world_xz(sunk, 5, 1000.0, 100.0, 0.0, 0.0)
	var detail_y := TerrainBuilder.height_at_world_xz_rect(detail_foot, 5, 5, 400.0, 100.0, 0.0, 0.0)
	var sample_y := TerrainBuilder.sample_footing_height(
		0.0, 0.0, sunk, 5, 1000.0, 100.0, detail_foot, 5, 5, 400.0)
	_check("footing prefers detail over sunk coarse", _approx(sample_y, detail_y, 0.01),
		"sample=%.2f detail=%.2f sunk=%.2f" % [sample_y, detail_y, sunk_y])
	_check("sunk coarse differs from detail centre", absf(sunk_y - detail_y) > 1.0)

	var flat := PackedFloat32Array()
	flat.resize(4)
	flat.fill(100.0)
	var square := PackedVector2Array([
		Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20),
	])
	var bdata := [{"points": square, "height_m": 12.0}]
	var node := BuildingBuilder.build_buildings_node(
		bdata, flat, 2, 30000.0, 100.0, null, null, 0.0)
	_check("building mesh node built", node != null)
	if node != null:
		var mi := node.get_node_or_null("BuildingMeshes") as MeshInstance3D
		_check("building mesh exists", mi != null and mi.mesh != null)
		node.free()


func _test_mesh() -> void:
	var res := 8
	var extent := 30000.0
	# A plane tilted so the SE corner is highest.
	var elev := PackedFloat32Array()
	elev.resize(res * res)
	for r in res:
		for c in res:
			elev[r * res + c] = float(r + c) * 10.0
	var center := TerrainBuilder.mean_elevation(elev)
	var mesh := TerrainBuilder.build_mesh(elev, res, extent, center)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	_check("mesh vertex count == res*res", verts.size() == res * res,
		"got %d" % verts.size())

	# NW corner (index 0) is lowest elevation → lowest y; SE corner highest.
	var y_nw := verts[0].y
	var y_se := verts[res * res - 1].y
	_check("displacement sign (SE higher than NW)", y_se > y_nw,
		"nw=%.1f se=%.1f" % [y_nw, y_se])

	# Horizontal extent matches; mesh centred on origin in X/Z.
	var aabb := mesh.get_aabb()
	_check("mesh spans extent in X", _approx(aabb.size.x, extent, 1.0),
		"got %.1f" % aabb.size.x)
	_check("mesh spans extent in Z", _approx(aabb.size.z, extent, 1.0),
		"got %.1f" % aabb.size.z)
	_check("mesh centred X", _approx(aabb.position.x + aabb.size.x * 0.5, 0.0, 1.0))
	_check("mesh centred Z", _approx(aabb.position.z + aabb.size.z * 0.5, 0.0, 1.0))

	# Normals must point up (winding correct) or the surface is invisible from above.
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var navg := Vector3.ZERO
	for nv in normals:
		navg += nv
	navg /= float(maxi(normals.size(), 1))
	_check("mesh normals point +Y (front face up)", navg.y > 0.5,
		"avg normal=%s" % str(navg))

	# UVs span 0..1.
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv_min := Vector2(INF, INF)
	var uv_max := Vector2(-INF, -INF)
	for uv in uvs:
		uv_min = uv_min.min(uv)
		uv_max = uv_max.max(uv)
	_check("UV min ~0", _approx(uv_min.x, 0.0, 1e-4) and _approx(uv_min.y, 0.0, 1e-4))
	_check("UV max ~1", _approx(uv_max.x, 1.0, 1e-4) and _approx(uv_max.y, 1.0, 1e-4))


func _test_terrain_node() -> void:
	var res := 16
	var elev := PackedFloat32Array()
	elev.resize(res * res)
	elev.fill(100.0)
	var center := TerrainBuilder.mean_elevation(elev)
	var node := TerrainBuilder.build_terrain_node(elev, res, 30000.0, center, null)
	_check("terrain node returned", node != null)
	var ground := node.get_node_or_null("Ground")
	_check("has Ground MeshInstance3D", ground is MeshInstance3D)
	var body := node.get_node_or_null("TerrainCollision")
	_check("has StaticBody3D", body is StaticBody3D)
	if body != null:
		var cs := body.get_child(0) as CollisionShape3D
		_check("collision shape is HeightMapShape3D", cs != null and cs.shape is HeightMapShape3D)
		if cs != null and cs.shape is HeightMapShape3D:
			var hm := cs.shape as HeightMapShape3D
			_check("heightmap dims", hm.map_width == res and hm.map_depth == res)
			# Collision scale aligns unit grid to mesh spacing.
			var spacing := 30000.0 / float(res - 1)
			_check("collision scaled to spacing", _approx(cs.scale.x, spacing, 0.5))
	node.free()


func _shader_param(mat: Material, name: String) -> Variant:
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter(name)
	return null


func _test_coarse_hide() -> void:
	var res := 8
	var elev := PackedFloat32Array()
	elev.resize(res * res)
	elev.fill(50.0)
	var center := TerrainBuilder.mean_elevation(elev)
	var node := TerrainBuilder.build_terrain_node(elev, res, 30000.0, center, null)
	_check("no DetailGround initially", not TerrainBuilder.has_detail_ground(node))

	var detail_elev := elev.duplicate()
	TerrainBuilder.upsert_detail_patch(
		node, detail_elev, res, 1000.0, center, null, null, 30000.0)
	_check("DetailGround after upsert", TerrainBuilder.has_detail_ground(node))
	_check("DetailCollision after upsert", node.get_node_or_null("DetailCollision") != null)

	var detail_body := node.get_node_or_null("DetailCollision") as StaticBody3D
	if detail_body != null:
		_check("detail collision child", detail_body.get_child_count() > 0)
		var dcs := detail_body.get_child(0) as CollisionShape3D
		_check("detail collision shape", dcs != null and dcs.shape != null)

	var ground := node.get_node_or_null("Ground") as MeshInstance3D
	var coarse_mat := ground.material_override if ground != null else null
	_check("coarse uses shader when hiding centre", coarse_mat is ShaderMaterial)
	_check("coarse hide_centre_region", _shader_param(coarse_mat, "hide_centre_region") == true)
	_check("coarse use_detail off", _shader_param(coarse_mat, "use_detail") == false)

	var detail_ground := node.get_node_or_null("DetailGround") as MeshInstance3D
	var detail_mat := detail_ground.material_override if detail_ground != null else null
	_check("detail patch_mesh", _shader_param(detail_mat, "patch_mesh") == true)
	_check("detail render priority above coarse",
		detail_mat.render_priority > coarse_mat.render_priority)

	TerrainBuilder.remove_detail_patch(node)
	var dg := node.get_node_or_null("DetailGround")
	if dg != null:
		dg.free()
	_check("DetailGround removed", not TerrainBuilder.has_detail_ground(node))
	node.free()


func _test_seam_compose() -> void:
	# Synthetic 100 m step: detail centre high, coarse low — compose should feather below 2 m.
	var coarse_res := 9
	var detail_res := 9
	var coarse := PackedFloat32Array()
	coarse.resize(coarse_res * coarse_res)
	coarse.fill(100.0)
	var detail := PackedFloat32Array()
	detail.resize(detail_res * detail_res)
	detail.fill(200.0)
	var center := 150.0
	var terrain_extent := 3000.0
	var detail_extent := 1000.0
	var feather := TerrainBuilder.compute_adaptive_feather_m(
		detail, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center)
	_check("adaptive feather >= min", feather >= TerrainBuilder.MIN_FEATHER_M)
	var aligned := TerrainBuilder.apply_detail_vertical_offset(detail, -100.0)
	var feathered := TerrainBuilder.feather_detail_to_coarse(
		aligned, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center, feather)
	var patched := TerrainBuilder.patch_centre_heights(
		coarse, coarse_res, feathered, detail_res, terrain_extent, detail_extent, feather)
	var exterior := TerrainBuilder.feather_coarse_exterior_ring(
		patched, coarse_res, terrain_extent, center,
		feathered, detail_res, detail_extent)
	var diag := TerrainSeamDiag.measure_boundary_delta(
		feathered, detail_res, detail_extent, exterior, coarse_res, terrain_extent, center)
	_check("seam max delta after compose < 2 m", float(diag.get("max_delta_m", 99.0)) < 2.0,
		"max=%.2f feather=%.0f" % [float(diag.get("max_delta_m", 0.0)), feather])
	var offset := TerrainBuilder.compute_detail_vertical_offset(
		detail, detail_res, detail_extent, coarse, coarse_res, terrain_extent, center)
	_check("vertical offset detects 100 m step", absf(absf(offset) - 100.0) < 5.0, "got %.1f" % offset)


func _test_aaigrid() -> void:
	# Minimal ESRI ASCII grid: 3×2, one NODATA cell.
	var text := "ncols 3\nnrows 2\nxllcorner 0.0\nyllcorner 0.0\ncellsize 0.01\nNODATA_value -9999\n10 20 30\n40 -9999 60\n"
	var parsed := ElevationServiceScript.parse_aaigrid(text)
	_check("aaigrid parsed", not parsed.is_empty())
	if not parsed.is_empty():
		_check("aaigrid cols/rows", int(parsed["cols"]) == 3 and int(parsed["rows"]) == 2)
		var g: PackedFloat32Array = parsed["grid"]
		_check("aaigrid size", g.size() == 6)
		_check("aaigrid north-first ordering", _approx(g[0], 10.0, 1e-6))
		_check("aaigrid NODATA→NAN", is_nan(g[4]))
		_check("aaigrid stores xllcorner", _approx(float(parsed.get("xllcorner", NAN)), 0.0, 1e-6))
		_check("aaigrid stores cellsize", _approx(float(parsed.get("cellsize", NAN)), 0.01, 1e-6))
	_check("aaigrid rejects malformed", ElevationServiceScript.parse_aaigrid("ncols 3\n1 2").is_empty())


func _test_aaigrid_georef() -> void:
	# 3×3 ramp; request a sub-bbox so naive stretch would disagree with georef.
	var text := "ncols 3\nnrows 3\nxllcorner -1.0\nyllcorner -1.0\ncellsize 1.0\nNODATA_value -9999\n"
	text += "9 8 7\n6 5 4\n3 2 1\n"
	var parsed := ElevationServiceScript.parse_aaigrid(text)
	_check("georef aaigrid parsed", not parsed.is_empty())
	if parsed.is_empty():
		return
	var bbox := {"north": 1.0, "south": -1.0, "east": 1.0, "west": -1.0}
	var grid := ElevationServiceScript.resample_aaigrid_to_bbox(parsed, bbox, 3)
	_check("georef resample size", grid.size() == 9, "got %d" % grid.size())
	if grid.size() == 9:
		# Cell centres: NW ≈ 9, centre ≈ 5, SE ≈ 1.
		_check("georef NW ~9", _approx(grid[0], 9.0, 1.5), "got %f" % grid[0])
		_check("georef centre ~5", _approx(grid[4], 5.0, 1.5), "got %f" % grid[4])
		_check("georef SE ~1", _approx(grid[8], 1.0, 1.5), "got %f" % grid[8])
	_check("georef empty without headers",
		ElevationServiceScript.resample_aaigrid_to_bbox(
			{"cols": 2, "rows": 2, "grid": PackedFloat32Array([1, 2, 3, 4])},
			bbox, 2).is_empty())


func _test_dem_extent_recovery() -> void:
	var half := ElevationServiceScript._half_extent_from_dem_filename(
		"dem_v4_base_opentopo_COP90_40.7871_-119.2025_60000_256.json")
	_check("dem filename half_extent", _approx(half, 60000.0, 0.1), "got %f" % half)
	var half2 := ElevationServiceScript._half_extent_from_dem_filename(
		"dem_v4_detail_opentopo_usgs10_40.7871_-119.2025_4000_512.json")
	_check("dem filename detail half", _approx(half2, 4000.0, 0.1), "got %f" % half2)


func _test_imagery_equirect_warp() -> void:
	# Exact bbox crop stays inside the mosaic and keeps a positive size.
	var bbox := {"west": -1.0, "east": 1.0, "north": 1.0, "south": -1.0}
	var rect := ImageryServiceScript.mercator_bbox_crop_rect(
		1024, 1024, 0, 0, 8, bbox)
	_check("mercator crop positive", rect.size.x > 0 and rect.size.y > 0)
	_check("mercator crop in bounds",
		rect.position.x >= 0 and rect.position.y >= 0
		and rect.end.x <= 1024 and rect.end.y <= 1024)
	var bb := TerrainBuilder.bbox_to_shader_vec4(
		{"west": -2.0, "east": 2.0, "south": -1.0, "north": 1.0})
	_check("bbox shader vec4 west", _approx(bb.x, -2.0, 1e-6))
	_check("bbox shader vec4 north", _approx(bb.w, 1.0, 1e-6))


func _test_osm_registration() -> void:
	var p0 := Vector2(100.0, 200.0)
	var p1: Vector2 = OsmRegistrationScript.offset_local_m(p0, 10.0, 20.0)
	_check("offset +E +N", _approx(p1.x, 110.0, 1e-6) and _approx(p1.y, 180.0, 1e-6))
	var payload := {
		"buildings": [{
			"points": PackedVector2Array([
				Vector2(-460.0, 420.0), Vector2(-450.0, 420.0),
				Vector2(-450.0, 430.0), Vector2(-460.0, 430.0),
			]),
			"tags": {"name": "The Man"},
		}],
	}
	var man: Vector2 = OsmRegistrationScript.find_brc_man_local(payload)
	_check("find BRC Man", is_finite(man.x) and _approx(man.x, -455.0, 0.1))
	# Map centre ≈ 2025 spike; OSM Man ≈ 2026 spike → ~400 m NE slide.
	var sug: Vector2 = OsmRegistrationScript.suggest_brc_offset_m(
		40.7870812, -119.2024765, payload)
	_check("BRC suggest length hundreds of m",
		sug.length() > 300.0 and sug.length() < 600.0,
		"got %.1f m" % sug.length())
	_check("BRC suggest moves Man NE onto scars",
		sug.x > 300.0 and sug.y > 300.0,
		"got E=%.1f N=%.1f" % [sug.x, sug.y])
	var shifted: Dictionary = OsmRegistrationScript.offset_payload(payload, sug.x, sug.y)
	var man2: Vector2 = OsmRegistrationScript.find_brc_man_local(shifted)
	_check("after offset Man near centre",
		man2.length() < 80.0, "got %.1f m from origin" % man2.length())


func _test_dem_usability() -> void:
	var flat := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	_check("flat 2x2 not usable", not ElevationServiceScript.grid_is_usable(flat, 2, 2))
	var real := PackedFloat32Array()
	real.resize(16)
	for i in 16:
		real[i] = 100.0 + float(i) * 0.5
	_check("16x1 relief usable", ElevationServiceScript.grid_is_usable(real, 4, 4))
	_check("daily limit detect",
		ElevationServiceScript._is_openmeteo_daily_limit(429,
			'{"error":true,"reason":"Daily API request limit exceeded. Please try again tomorrow."}'))
	_check("concurrent 429 not daily",
		not ElevationServiceScript._is_openmeteo_daily_limit(429, ""))


func _test_cache_settings() -> void:
	var lat := 46.2445
	var lon := -121.0722
	var token := TerrainCacheSettings.coord_token(lat, lon)
	_check("coord token format", token == "46.2445_-121.0722")
	_check("warm cache false for unused site",
		not TerrainCacheSettings.has_warm_cache(-48.0, 88.0))
	var dem_dir := TerrainCacheSettings.DEM_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dem_dir))
	var keep := "%s/dem_other_47.0000_-122.0000_15000.json" % dem_dir
	var drop := "%s/dem_selftest_%s_15000.json" % [dem_dir, token]
	for p in [keep, drop]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string("{}")
			f.close()
	var removed := TerrainCacheSettings.invalidate_dem(lat, lon)
	_check("invalidate_dem removes site files", removed >= 1, "removed %d" % removed)
	_check("other site dem file kept", FileAccess.file_exists(keep))
	if FileAccess.file_exists(drop):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(drop))
	if FileAccess.file_exists(keep):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(keep))


func _test_base_grid_extent() -> void:
	var n30 := ElevationServiceScript.base_grid_n_for_extent(15000.0)
	_check("base grid 30 km >= cfg default", n30 >= 64, "got %d" % n30)
	var n50 := ElevationServiceScript.base_grid_n_for_extent(50000.0)
	_check("base grid 50 km > 30 km", n50 > n30, "%d vs %d" % [n50, n30])
	_check("base grid capped", n50 <= 256, "got %d" % n50)
	_check("large world uses COP90", ElevationServiceScript.opentopo_global_demtype(50000.0, "base") == "COP90")
	_check("small world uses SRTMGL1", ElevationServiceScript.opentopo_global_demtype(5000.0, "base") == "SRTMGL1")
	_check("mid world uses SRTMGL3", ElevationServiceScript.opentopo_global_demtype(15000.0, "base") == "SRTMGL3")


func _test_load_progress() -> void:
	var p := TerrainLoadProgress.new()
	p.configure_for_extents(50000.0, 2000.0)
	p.set_partial("base_dem", 0.2)
	_check("extent label world", "100 km" in p.active_label())
	p.mark_done("base_dem")
	p.mark_done("base_img")
	p.mark_done("walkable")
	p.set_partial("detail_dem", 0.5)
	_check("extent label detail", "4.0 km" in p.active_label())
	_check("load progress partial", p.fraction() > 0.3 and p.fraction() < 0.6,
		"got %.3f" % p.fraction())
	p.mark_done("detail_dem")
	p.mark_done("detail_img")
	p.mark_done("osm_map")
	p.mark_done("osm_veg")
	_check("load progress complete", p.is_complete() and _approx(p.fraction(), 1.0, 1e-6))
	_check("complete label", p.active_label() == "Map loaded")


func _test_sculpt_ops() -> void:
	var res := 17
	var extent := 160.0
	var base := PackedFloat32Array()
	base.resize(res * res)
	base.fill(100.0)
	var delta := PackedFloat32Array()
	delta.resize(res * res)
	delta.fill(0.0)
	var rmin := Vector2(-20.0, -20.0)
	var rmax := Vector2(20.0, 20.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "hill", 4.0, 2.0, base, 100.0)
	var c := TerrainSculpt.world_to_cell(0.0, 0.0, res, extent)
	var edge := TerrainSculpt.world_to_cell(18.0, 0.0, res, extent)
	_check("sculpt hill peaks at centre",
		delta[c.y * res + c.x] > delta[edge.y * res + edge.x] + 0.5,
		"mid=%f edge=%f" % [delta[c.y * res + c.x], delta[edge.y * res + edge.x]])
	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "berm", 3.0, 2.0, base, 100.0)
	var crest := TerrainSculpt.world_to_cell(0.0, 0.0, res, extent)
	var flank := TerrainSculpt.world_to_cell(0.0, 18.0, res, extent)
	_check("sculpt berm crest > flank",
		delta[crest.y * res + crest.x] > delta[flank.y * res + flank.x] + 0.3,
		"crest=%f flank=%f" % [delta[crest.y * res + crest.x], delta[flank.y * res + flank.x]])
	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "swale", 3.0, 2.0, base, 100.0)
	_check("sculpt swale digs below zero",
		delta[crest.y * res + crest.x] < -0.5,
		"got %f" % delta[crest.y * res + crest.x])
	delta.fill(0.0)
	TerrainSculpt.apply_rect(delta, res, extent, rmin, rmax, "level", 5.0, 4.0, base, 100.0)
	_check("sculpt level mid near target",
		_approx(delta[c.y * res + c.x], 5.0, 0.6),
		"got %f" % delta[c.y * res + c.x])

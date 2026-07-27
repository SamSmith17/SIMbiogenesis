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
	_test_edit_tiles()
	_test_sculpt_ops_v2()
	_test_pallet_rack()
	_test_pallet_rack_editor()
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
	var rack := PalletRackBuilder.build_node({"bay_count": 2, "column_count": 2})
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


func _test_pallet_rack() -> void:
	# Catalog snapping + clamps.
	var s := PalletRackBuilder.resolve_spec({
		"upright_depth_in": 40, "upright_height_ft": 15, "beam_span_ft": 13,
		"lumber_len_ft": 13, "joist_spacing_in": 21, "bay_count": 99, "column_count": 0,
		"deck_levels": 9,
	})
	_check("rack snap depth 40->42", int(s["upright_depth_in"]) == 42)
	_check("rack snap height 15->16", int(s["upright_height_ft"]) == 16)
	_check("rack snap beam 13->12", int(s["beam_span_ft"]) == 12)
	_check("rack snap lumber 13->12", int(s["lumber_len_ft"]) == 12)
	_check("rack snap joist 21->24", int(s["joist_spacing_in"]) == 24)
	_check("rack clamp bays", int(s["bay_count"]) == 10)
	_check("rack clamp columns", int(s["column_count"]) == 1)
	_check("rack clamp levels", int(s["deck_levels"]) == 3)
	_check("rack level heights len matches", (s["level_heights_ft"] as Array).size() == 3)

	# Legacy metric spec mapping.
	var lg := PalletRackBuilder.resolve_spec({"width_m": 3.66, "depth_m": 1.07, "levels": 2})
	_check("rack legacy maps beam span", int(lg["beam_span_ft"]) == 12)
	_check("rack legacy maps depth", int(lg["upright_depth_in"]) == 42)
	_check("rack legacy single column", int(lg["column_count"]) == 1)
	_check("rack legacy not decked", bool(lg["decked"]) == false)

	# Footprint math.
	var fp := PalletRackBuilder.footprint_xz({"beam_span_ft": 12, "bay_count": 3,
		"upright_depth_in": 42, "column_count": 2, "lumber_len_ft": 12})
	var module_x := 12.0 * PalletRackBuilder.FT + PalletRackBuilder.POST_W
	_check("rack footprint x", _approx(fp.x, 3.0 * module_x, 0.01), "got %f" % fp.x)
	_check("rack footprint z positive", fp.y > 0.0)

	# BOM counts for a known config (no variants): rows=cols+1.
	var b := PalletRackBuilder.bom({"bay_count": 3, "column_count": 2, "deck_levels": 2,
		"roof_deck": false, "decked": true, "u_shape": false, "stepped_module": 0})
	_check("rack bom uprights = rows*(bays+1)", int(b["uprights"]) == 3 * 4,
		"got %d" % int(b["uprights"]))
	_check("rack bom beams = levels*rows*bays*2", int(b["beams"]) == 2 * 3 * 3 * 2,
		"got %d" % int(b["beams"]))
	_check("rack bom has plywood when decked", int(b["plywood"]) > 0)
	_check("rack bom has lumber when decked", int(b["lumber"]) > 0)

	# Decking off → no plywood/lumber (no roof).
	var b0 := PalletRackBuilder.bom({"bay_count": 3, "column_count": 2, "deck_levels": 2,
		"roof_deck": false, "decked": false})
	_check("rack bom no plywood undecked", int(b0["plywood"]) == 0)
	_check("rack bom no lumber undecked", int(b0["lumber"]) == 0)

	# Occupancy grid + U-notch carving.
	var grid := PalletRackBuilder.deck_grid({"bay_count": 4, "column_count": 3,
		"decked": true, "u_shape": false})
	_check("rack grid dims", grid.size() == 4 and (grid[0] as Array).size() == 3)
	var full_decked := 0
	for row in grid:
		for cell in row:
			if bool(cell):
				full_decked += 1
	_check("rack grid all decked", full_decked == 12)
	var ugrid := PalletRackBuilder.deck_grid({"bay_count": 4, "column_count": 3,
		"decked": true, "u_shape": true, "u_open_bays": 2, "u_open_cols": 2})
	var u_decked := 0
	for row in ugrid:
		for cell in row:
			if bool(cell):
				u_decked += 1
	_check("rack u-notch carves decks", u_decked < full_decked,
		"full=%d u=%d" % [full_decked, u_decked])

	# U-shape removes interior uprights vs the full rectangle.
	var bfull := PalletRackBuilder.bom({"bay_count": 4, "column_count": 3, "u_shape": false})
	var bu := PalletRackBuilder.bom({"bay_count": 4, "column_count": 3, "u_shape": true,
		"u_open_bays": 2, "u_open_cols": 2})
	_check("rack u-shape removes uprights", int(bu["uprights"]) < int(bfull["uprights"]),
		"full=%d u=%d" % [int(bfull["uprights"]), int(bu["uprights"])])

	# Merged mesh: one MeshInstance3D with 1-4 material surfaces.
	var node := PalletRackBuilder.build_node({"bay_count": 2, "column_count": 2})
	var mi := node.get_node_or_null("RackMesh") as MeshInstance3D
	_check("rack single mesh instance", mi != null and mi.mesh != null)
	if mi != null and mi.mesh != null:
		var sc := mi.mesh.get_surface_count()
		_check("rack merged surfaces 1..4", sc >= 1 and sc <= 4, "got %d" % sc)
		_check("rack mesh has geometry", mi.mesh.get_faces().size() > 0)
	node.free()


func _test_pallet_rack_editor() -> void:
	# resolve_spec normalizes the override containers even for legacy specs.
	var legacy := PalletRackBuilder.resolve_spec({"bay_count": 2, "column_count": 1})
	_check("editor cell_overrides container", legacy.get("cell_overrides") is Dictionary)
	_check("editor beam_overrides container", legacy.get("beam_overrides") is Dictionary)
	_check("editor wall_sheet_deleted container", legacy.get("wall_sheet_deleted") is Array)

	# Pick registry: default decked rack yields deck cells, beams, and uprights.
	var base := {"bay_count": 3, "column_count": 2, "deck_levels": 2, "decked": true,
		"roof_deck": false, "u_shape": false, "stepped_module": 0}
	var comps := PalletRackBuilder.pick_components(base)
	var n_cell := 0
	var n_beam := 0
	var n_post := 0
	for comp in comps:
		match str(comp["kind"]):
			"deck", "step": n_cell += 1
			"beam": n_beam += 1
			"upright": n_post += 1
	_check("editor picks deck cells", n_cell == 2 * 2 * 3, "got %d" % n_cell)
	_check("editor picks beams", n_beam == 2 * 3 * 3 * 2, "got %d" % n_beam)
	_check("editor picks uprights", n_post == 3 * 4, "got %d" % n_post)

	# Ray-AABB helper: a ray down +Z through the origin hits a box there; an
	# off-axis ray misses.
	var box := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	_check("ray hits centered box",
		PalletRackBuilder.ray_hits_aabb(Vector3(0, 0, -10), Vector3(0, 0, 1), box) > 0.0)
	_check("ray misses offset box",
		PalletRackBuilder.ray_hits_aabb(Vector3(10, 0, -10), Vector3(0, 0, 1), box) < 0.0)

	# Raising a cell lifts its pick AABB.
	var cell_id := ""
	var cell_aabb: AABB
	for comp in comps:
		if str(comp["kind"]) == "deck":
			cell_id = str(comp["id"])
			cell_aabb = comp["aabb"]
			break
	_check("editor has a deck cell id", cell_id.begins_with("cell:"))
	var key := cell_id.substr(cell_id.find(":") + 1)
	var raised := base.duplicate(true)
	raised["cell_overrides"] = {key: {"height_ft": 12.0}}
	var raised_comp := {}
	for comp in PalletRackBuilder.pick_components(raised):
		if str(comp["id"]) == cell_id:
			raised_comp = comp
			break
	_check("editor raise lifts cell aabb",
		not raised_comp.is_empty()
		and (raised_comp["aabb"] as AABB).position.y > cell_aabb.position.y + 1.0)

	# Removing a cell (kind none) drops it from the registry and the plywood BOM.
	var full_bom := PalletRackBuilder.bom(base)
	var removed := base.duplicate(true)
	removed["cell_overrides"] = {key: {"kind": "none"}}
	var removed_bom := PalletRackBuilder.bom(removed)
	_check("editor remove cell drops plywood",
		int(removed_bom["plywood"]) < int(full_bom["plywood"]),
		"full=%d removed=%d" % [int(full_bom["plywood"]), int(removed_bom["plywood"])])
	var still_there := false
	for comp in PalletRackBuilder.pick_components(removed):
		if str(comp["id"]) == cell_id:
			still_there = true
	_check("editor removed cell not pickable", not still_there)

	# depth_units shortens a cell's Z extent.
	var shortened := base.duplicate(true)
	shortened["cell_overrides"] = {key: {"depth_units": 1}}
	var short_comp := {}
	for comp in PalletRackBuilder.pick_components(shortened):
		if str(comp["id"]) == cell_id:
			short_comp = comp
	_check("editor depth_units shortens cell",
		not short_comp.is_empty()
		and float(short_comp["z1"]) < float(cell_aabb.position.z + cell_aabb.size.z) - 0.5)

	# Deleting a beam removes it from BOM + registry.
	var beam_id := ""
	for comp in comps:
		if str(comp["kind"]) == "beam":
			beam_id = str(comp["id"])
			break
	var bkey := beam_id.substr(beam_id.find(":") + 1)
	var beam_del := base.duplicate(true)
	beam_del["beam_overrides"] = {bkey: {"deleted": true}}
	_check("editor delete beam drops bom",
		int(PalletRackBuilder.bom(beam_del)["beams"]) == int(full_bom["beams"]) - 1)

	# Legacy stepped_module migrates to per-cell step overrides.
	var stepped := PalletRackBuilder.resolve_spec({"bay_count": 2, "column_count": 2,
		"deck_levels": 2, "decked": true, "roof_deck": true, "stepped_module": 1})
	var cov: Dictionary = stepped["cell_overrides"]
	var any_step := false
	for k in cov.keys():
		if str((cov[k] as Dictionary).get("kind", "")) == "step":
			any_step = true
	_check("editor stepped_module migrates to step cells", any_step,
		"cov=%s" % str(cov))

	# Wall-sheet deletion cuts a sheet from the plywood BOM.
	var walled := {"bay_count": 2, "column_count": 1, "decked": false, "roof_deck": false,
		"walls": {"front": true, "back": false, "left": false, "right": false}}
	var walled_bom := PalletRackBuilder.bom(walled)
	var sheet_id := ""
	for comp in PalletRackBuilder.pick_components(walled):
		if str(comp["kind"]) == "wall_sheet":
			sheet_id = str(comp["id"])
			break
	_check("editor wall has pickable sheets", sheet_id.begins_with("wall:"))
	if sheet_id.begins_with("wall:"):
		var wkey := sheet_id.substr(sheet_id.find(":") + 1)
		var wall_del := walled.duplicate(true)
		wall_del["wall_sheet_deleted"] = [wkey]
		_check("editor wall sheet delete cuts opening",
			int(PalletRackBuilder.bom(wall_del)["plywood"]) < int(walled_bom["plywood"]))

	# cell_slots enumerates EVERY grid cell (incl. empty) for the step tool, and
	# a removed/undecked cell still appears as a droppable slot.
	var undecked := {"bay_count": 2, "column_count": 1, "deck_levels": 1,
		"decked": false, "roof_deck": false}
	var slots := PalletRackBuilder.cell_slots(undecked)
	_check("editor cell_slots covers full grid", slots.size() == 2 * 1 * 1,
		"got %d" % slots.size())
	var empty_slot := false
	for slot in slots:
		if str(slot["kind"]) == "none":
			empty_slot = true
	_check("editor cell_slots exposes empty cells", empty_slot)
	# Dropping a step there produces a step cell in emission.
	if not slots.is_empty():
		var skey := str(slots[0]["id"]).substr(str(slots[0]["id"]).find(":") + 1)
		var stepped_slot := undecked.duplicate(true)
		stepped_slot["cell_overrides"] = {skey: {"kind": "step"}}
		_check("editor step drop adds lumber",
			int(PalletRackBuilder.bom(stepped_slot)["lumber"]) > 0)

	# Modal script compiles + builds its UI/studio without autoloads at runtime.
	var ModalScript: GDScript = load("res://scenes/ui/pallet_rack_builder_modal.gd")
	_check("editor modal script loads", ModalScript != null)
	if ModalScript != null:
		var modal: Control = ModalScript.new()
		get_root().add_child(modal)
		# _ready is deferred under --script; call it directly to build the UI.
		modal.call("_ready")
		_check("editor modal builds ui", modal.get_child_count() > 0)
		modal.free()


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

	var ci := c.y * res + c.x
	var ei := edge.y * res + edge.x

	# Brush raise / lower with radial falloff.
	delta.fill(0.0)
	var touched := TerrainSculpt.apply_brush(delta, res, extent, Vector2.ZERO, 40.0, 5.0, 0.0, "raise", base, 100.0)
	_check("brush raise reports touch", touched != TerrainSculpt.NO_TOUCH)
	_check("brush raise centre positive", delta[ci] > 0.5, "got %f" % delta[ci])
	_check("brush raise tapers to edge (soft)", delta[ci] > delta[ei], "mid=%f edge=%f" % [delta[ci], delta[ei]])
	delta.fill(0.0)
	TerrainSculpt.apply_brush(delta, res, extent, Vector2.ZERO, 40.0, 5.0, 0.5, "lower", base, 100.0)
	_check("brush lower digs", delta[ci] < -0.5, "got %f" % delta[ci])

	# Smooth relaxes a spike toward its neighbourhood.
	delta.fill(0.0)
	delta[ci] = 10.0
	for _i in 25:
		TerrainSculpt.apply_brush(delta, res, extent, Vector2.ZERO, 40.0, 1.0, 0.0, "smooth", base, 100.0)
	_check("brush smooth reduces spike", delta[ci] < 8.0, "got %f" % delta[ci])

	# Flatten converges the surface toward the brush-down target height.
	delta.fill(0.0)
	for _i in 40:
		TerrainSculpt.apply_brush(delta, res, extent, Vector2.ZERO, 40.0, 1.0, 1.0, "flatten", base, 100.0, 5.0)
	_check("brush flatten converges to target", _approx(delta[ci], 5.0, 0.6), "got %f" % delta[ci])

	# Pond stamp: deeper at centre, additive per click.
	delta.fill(0.0)
	TerrainSculpt.apply_pond_stamp(delta, res, extent, Vector2.ZERO, 40.0, 2.0)
	var d1 := delta[ci]
	_check("pond stamp digs bowl", d1 < 0.0, "got %f" % d1)
	_check("pond bowl deeper at centre than rim", delta[ci] < delta[ei], "mid=%f rim=%f" % [delta[ci], delta[ei]])
	TerrainSculpt.apply_pond_stamp(delta, res, extent, Vector2.ZERO, 40.0, 2.0)
	_check("pond stamp additive deepens", delta[ci] < d1 - 0.5, "d1=%f d2=%f" % [d1, delta[ci]])

	# Polygon-mask op feathers toward the edge.
	delta.fill(0.0)
	var poly := PackedVector2Array([Vector2(-40, -40), Vector2(40, -40), Vector2(40, 40), Vector2(-40, 40)])
	TerrainSculpt.apply_polygon_op(delta, res, extent, poly, "raise", 5.0, 20.0, base, 100.0)
	var pe := TerrainSculpt.world_to_cell(38.0, 0.0, res, extent)
	_check("polygon raise fills centre", delta[ci] > 4.0, "got %f" % delta[ci])
	_check("polygon feathers at edge", delta[pe.y * res + pe.x] < delta[ci] - 0.5,
		"centre=%f edge=%f" % [delta[ci], delta[pe.y * res + pe.x]])

	_test_edit_grid_v2()
	_test_earthworks()
	_test_depression_fill()
	_test_pond_bathymetry()


func _test_pond_bathymetry() -> void:
	# Parabolic bowl: floor 8 m at centre, spill ~10 m at r=18.
	var height_at := func(x: float, z: float) -> float:
		var r := sqrt(x * x + z * z)
		if r >= 18.0:
			return 10.0
		return 10.0 - 2.0 * (1.0 - r / 18.0) * (1.0 - r / 18.0)
	var poly := VegetationPaint.circle_polygon(Vector2.ZERO, 18.0, 28)
	var floor_m := 8.0
	var spill_m := 10.0
	var cell := 1.25
	var empty_v := PondBathymetry.volume_to_level_l(poly, height_at, floor_m, cell, spill_m)
	_check("bathymetry empty near floor", empty_v < 500.0, "got %f" % empty_v)
	# Near-spill surface holds most of the litres (bowl flares outward).
	var mid_v := PondBathymetry.volume_to_level_l(poly, height_at, 9.7, cell, spill_m)
	var cap_v := PondBathymetry.capacity_l(poly, height_at, spill_m, 0.05, cell)
	_check("bathymetry mid < capacity", mid_v > empty_v and mid_v < cap_v,
		"mid=%f cap=%f" % [mid_v, cap_v])
	_check("bathymetry capacity substantial", cap_v > 5000.0, "cap=%f" % cap_v)
	var frac := PondBathymetry.fill_frac(mid_v, cap_v)
	_check("bathymetry fill frac mid", frac > 0.2 and frac < 0.98, "frac=%f" % frac)
	var lvl := PondBathymetry.level_for_volume_l(
		poly, height_at, mid_v, floor_m, spill_m, cell)
	_check("bathymetry inverse ~ mid level", absf(lvl - 9.7) < 0.25, "lvl=%f" % lvl)
	# Manual capacity must not be confused with terrain integral in callers —
	# fill_frac uses whatever capacity is passed.
	_check("bathymetry manual cap fill",
		PondBathymetry.fill_frac(5000.0, 10000.0) == 0.5)
	var diag := Watershed.analyze_primary_basin(poly, height_at, 2.0, 0.10, 20.0)
	_check("analyze_primary_basin valid bowl", bool(diag.get("valid", false)),
		"reason=%s" % str(diag.get("reason", "")))
	var flat_at := func(_x: float, _z: float) -> float: return 5.0
	var flat_diag := Watershed.analyze_primary_basin(
		VegetationPaint.circle_polygon(Vector2.ZERO, 30.0, 28), flat_at, 2.0, 0.10, 20.0)
	_check("analyze_primary_basin flat → no_closed_basin",
		not bool(flat_diag.get("valid", false))
		and str(flat_diag.get("reason", "")) == "no_closed_basin",
		"got %s" % str(flat_diag.get("reason", "")))


func _test_depression_fill() -> void:
	# Synthetic bowl: flat 10 m rim, 2 m deep pit at the centre. Selection covers
	# the bowl so gravity fill should return one pond near the spill height.
	var height_at := func(x: float, z: float) -> float:
		var r := sqrt(x * x + z * z)
		if r >= 18.0:
			return 10.0
		return 10.0 - 2.0 * (1.0 - r / 18.0) * (1.0 - r / 18.0)
	var sel := VegetationPaint.circle_polygon(Vector2.ZERO, 30.0, 28)
	var bodies: Array = Watershed.fill_depressions_in_polygon(
		sel, height_at, 1.0, 2.0, 0.08, 20.0)
	_check("depression fill finds a pond", bodies.size() >= 1, "got %d" % bodies.size())
	if bodies.is_empty():
		return
	var b: Dictionary = bodies[0]
	var level := float(b.get("level_m", 0.0))
	var poly: PackedVector2Array = b.get("points", PackedVector2Array())
	_check("depression fill level near spill (~10 m)",
		level > 9.4 and level < 10.2, "level=%f" % level)
	_check("depression fill footprint has area",
		BuildingBuilder.footprint_area_m2(poly) > 20.0,
		"area=%f" % BuildingBuilder.footprint_area_m2(poly))
	# Half-full should sit between pit (~8 m) and spill (~10 m).
	var half: Array = Watershed.fill_depressions_in_polygon(
		sel, height_at, 0.5, 2.0, 0.08, 20.0)
	if not half.is_empty():
		var hl := float((half[0] as Dictionary).get("level_m", 0.0))
		_check("depression fill 50% between pit and spill",
			hl > 8.2 and hl < 9.8, "level=%f" % hl)
	# Flat ground → no closed depression.
	var flat_at := func(_x: float, _z: float) -> float: return 5.0
	var none: Array = Watershed.fill_depressions_in_polygon(
		sel, flat_at, 1.0, 2.0, 0.08, 20.0)
	_check("depression fill ignores flats", none.is_empty(), "got %d" % none.size())


func _test_earthworks() -> void:
	var poly := PackedVector2Array([
		Vector2(-20, -10), Vector2(20, -10), Vector2(20, 10), Vector2(-20, 10)])
	var base_fn := func(x: float, z: float) -> float: return 50.0
	var sheer := EarthworksBuilder.build_raise(poly, 3.0, 0.0, base_fn)
	_check("earthworks sheer raise builds mesh", not sheer.is_empty() and sheer.get("mesh") != null)
	_check("earthworks sheer top_y", _approx(float(sheer.get("top_y", 0.0)), 53.0, 0.05),
		"got %s" % str(sheer.get("top_y")))
	var soft := EarthworksBuilder.build_raise(poly, 3.0, 1.0, base_fn)
	_check("earthworks soft raise builds mesh", not soft.is_empty() and soft.get("mesh") != null)
	# Soft embankment insets the top — verify offset_poly shrinks.
	var inset := EarthworksBuilder.offset_poly(poly, 3.0 * EarthworksBuilder.SLOPE_RUN_PER_RISE)
	var soft_area := BuildingBuilder.footprint_area_m2(inset)
	var base_area := BuildingBuilder.footprint_area_m2(poly)
	_check("earthworks soft top smaller than base", soft_area < base_area - 1.0,
		"soft=%f base=%f" % [soft_area, base_area])
	var walls := EarthworksBuilder.build_cut_walls(poly, 2.0, 0.0, base_fn)
	_check("earthworks sheer cut walls", not walls.is_empty())
	var no_walls := EarthworksBuilder.build_cut_walls(poly, 2.0, 0.95, base_fn)
	_check("earthworks soft cut skips walls", no_walls.is_empty())
	var tag1 := EarthworksBuilder.basin_tag_from_poly(poly)
	var tag2 := EarthworksBuilder.basin_tag_from_poly(poly)
	_check("earthworks basin tag stable", tag1 == tag2 and tag1.begins_with("sculpt_pond_"))
	var rec := {"points": poly, "kind": "raise", "top_y": 53.0}
	_check("earthworks height_at_raise inside",
		_approx(EarthworksBuilder.height_at_raise(rec, 0.0, 0.0), 53.0, 0.01))
	_check("earthworks height_at_raise outside",
		is_nan(EarthworksBuilder.height_at_raise(rec, 100.0, 100.0)))


func _test_edit_grid_v2() -> void:
	var eg := TerrainEditGrid.create_empty(8)
	eg.ensure_detail(4, 100.0)
	_check("editgrid detail alloc", eg.detail_delta.size() == 16 and eg.detail_res == 4)
	eg.detail_delta[5] = 3.0
	var base4 := PackedFloat32Array()
	base4.resize(16)
	base4.fill(50.0)
	var applied := eg.apply_detail_to(base4, 4, 100.0)
	_check("editgrid apply_detail adds", _approx(applied[5], 53.0, 1e-4), "got %f" % applied[5])
	_check("editgrid apply_detail leaves others", _approx(applied[0], 50.0, 1e-4))
	# Resolution change preserves edits (resampled).
	eg.ensure_detail(8, 100.0)
	_check("editgrid detail resized", eg.detail_delta.size() == 64 and eg.detail_res == 8)
	_check("editgrid detail has_edits after resize", eg.has_detail_edits())

	# Save / load v2 round-trip.
	var slat := 12.3456
	var slon := -65.4321
	eg.delta.fill(0.0)
	eg.delta[0] = 1.5
	eg.save(slat, slon)
	var eg2 := TerrainEditGrid.create_empty(8)
	_check("editgrid v2 load", eg2.load_for_map(slat, slon))
	_check("editgrid coarse round-trip", _approx(eg2.delta[0], 1.5, 1e-4), "got %f" % eg2.delta[0])
	_check("editgrid detail round-trip", eg2.detail_res == 8 and eg2.detail_delta.size() == 64)
	var sp := eg.save_path_for_map(slat, slon)
	if FileAccess.file_exists(sp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))

	# v1 migration: a legacy file (only `delta`) loads with an empty detail layer.
	var mlat := 9.8765
	var mlon := 4.3210
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var eg3 := TerrainEditGrid.create_empty(4)
	var v1delta: Array = []
	for i in 16:
		v1delta.append(2.0 if i == 3 else 0.0)
	var f := FileAccess.open(eg3.save_path_for_map(mlat, mlon), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": 1, "res": 4, "delta": v1delta}))
		f.close()
	var eg4 := TerrainEditGrid.create_empty(4)
	_check("editgrid v1 migrate loads", eg4.load_for_map(mlat, mlon))
	_check("editgrid v1 coarse intact", _approx(eg4.delta[3], 2.0, 1e-4), "got %f" % eg4.delta[3])
	_check("editgrid v1 has no detail layer", eg4.detail_delta.is_empty())
	var mp := eg3.save_path_for_map(mlat, mlon)
	if FileAccess.file_exists(mp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(mp))


func _test_edit_tiles() -> void:
	var t := TerrainEditTiles.new()
	_check("edittiles empty on create", t.is_empty())
	# A single-sample edit allocates exactly the tiles that own it.
	t.set_delta_sample(10, 10, 5.0)
	_check("edittiles read back", _approx(t.get_delta_sample(10, 10), 5.0, 1e-5))
	_check("edittiles zero elsewhere", _approx(t.get_delta_sample(11, 10), 0.0, 1e-5))
	_check("edittiles not empty after edit", not t.is_empty())

	# Shared-edge write: a sample on a tile boundary is visible from both tiles.
	var n := TerrainEditTiles.TILE_CELLS
	t.set_delta_sample(n, n, 7.0)  # boundary of 4 tiles
	_check("edittiles boundary sample stored", _approx(t.get_delta_sample(n, n), 7.0, 1e-5))
	# Sample n is the shared corner of tiles (0,0),(1,0),(0,1),(1,1).
	var owners := 0
	for key in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		if t.active_tiles().has(key):
			owners += 1
	_check("edittiles boundary shared by 4 tiles", owners == 4, "got %d" % owners)

	# Bilinear sampling between two samples.
	t.clear()
	t.set_delta_sample(0, 0, 0.0)
	t.set_delta_sample(1, 0, 2.0)
	var mid := t.sample_delta(TerrainEditTiles.CELL_M * 0.5, 0.0)
	_check("edittiles bilinear midpoint", _approx(mid, 1.0, 1e-4), "got %f" % mid)

	# Dirty tracking is consumed once.
	var dirty := t.consume_dirty()
	_check("edittiles dirty non-empty", dirty.size() > 0)
	_check("edittiles dirty cleared", not t.has_dirty())

	# Prune flat tiles: zeroing a tile drops it.
	t.clear()
	t.set_delta_sample(200, 200, 3.0)
	t.set_delta_sample(200, 200, 0.0)
	t.prune_flat_tiles()
	_check("edittiles prune flat", t.active_tiles().is_empty())

	# Binary round-trip.
	t.clear()
	t.set_delta_sample(5, 5, 4.25)
	t.set_delta_sample(6, 5, -2.5)
	var bytes := t.to_bytes()
	var t2 := TerrainEditTiles.new()
	_check("edittiles bytes load", t2.from_bytes(bytes))
	_check("edittiles round-trip a", _approx(t2.get_delta_sample(5, 5), 4.25, 1e-4))
	_check("edittiles round-trip b", _approx(t2.get_delta_sample(6, 5), -2.5, 1e-4))

	# Migration: bake a legacy delta grid (all +3 over a 100 m patch).
	var t3 := TerrainEditTiles.new()
	var res := 8
	var g := PackedFloat32Array()
	g.resize(res * res)
	g.fill(3.0)
	t3.bake_delta_grid(g, res, 100.0)
	_check("edittiles bake grid centre", _approx(t3.sample_delta(0.0, 0.0), 3.0, 0.05),
		"got %f" % t3.sample_delta(0.0, 0.0))

	# Migration via bake_delta_fn (earthworks path): a constant +2 over an AABB.
	var tf := TerrainEditTiles.new()
	tf.bake_delta_fn(Rect2(-10, -10, 20, 20), func(_x: float, _z: float) -> float: return 2.0)
	_check("edittiles bake_fn centre", _approx(tf.sample_delta(0, 0), 2.0, 0.05),
		"got %f" % tf.sample_delta(0, 0))
	_check("edittiles bake_fn outside", absf(tf.sample_delta(60, 60)) < 0.05)

	# Tile mesh arrays build with the expected vertex count and finite heights.
	var t4 := TerrainEditTiles.new()
	t4.set_delta_sample(2, 2, 6.0)
	var base_fn := func(_x: float, _z: float) -> float: return 100.0
	var arrays := t4.build_tile_arrays(Vector2i(0, 0), base_fn, 100.0, 0.001, 0.5)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var e := TerrainEditTiles.TILE_CELLS + 1
	_check("edittiles mesh vert count", verts.size() == e * e, "got %d" % verts.size())
	# Delta of +6 at sample (2,2) should lift that vertex ~6 m above center-relative 0.
	var lifted := verts[2 * e + 2].y
	_check("edittiles mesh applies delta", _approx(lifted, 6.0, 0.01), "got %f" % lifted)
	var hm := t4.build_tile_heightmap(Vector2i(0, 0), base_fn, 100.0)
	_check("edittiles heightmap size", hm.size() == e * e)

	# Region-scoped undo: a session captures only touched tiles; apply_snapshot
	# restores them and yields a redo snapshot.
	var t5 := TerrainEditTiles.new()
	t5.set_delta_sample(3, 3, 1.0)
	t5.begin_session()
	t5.set_delta_sample(3, 3, 9.0)
	t5.set_delta_sample(500, 500, 4.0)  # a brand-new tile
	var undo_snap := t5.end_session()
	_check("edittiles session touched two regions", undo_snap.size() >= 2,
		"got %d" % undo_snap.size())
	var redo_snap := t5.apply_snapshot(undo_snap)
	_check("edittiles undo restores value", _approx(t5.get_delta_sample(3, 3), 1.0, 1e-4),
		"got %f" % t5.get_delta_sample(3, 3))
	_check("edittiles undo removes new tile", _approx(t5.get_delta_sample(500, 500), 0.0, 1e-4))
	t5.apply_snapshot(redo_snap)
	_check("edittiles redo reapplies value", _approx(t5.get_delta_sample(3, 3), 9.0, 1e-4))
	_check("edittiles redo restores new tile", _approx(t5.get_delta_sample(500, 500), 4.0, 1e-4))

	# Overlay renderer invariant: the tile-mesh skirt must reach BELOW the sunk
	# DetailGround (60 m headroom in terrain_loader) or the sink chasm shows at
	# a cut's tile boundary. The loader has no class_name, so its constant is
	# read off a throwaway instance.
	var loader_script: GDScript = load("res://core/terrain/terrain_loader.gd")
	var sink_headroom: float = loader_script.get_script_constant_map().get(
		"TILE_SINK_HEADROOM_M", 60.0)
	_check("heightfield skirt seals the sink",
		TerrainHeightField.SKIRT_DROP_M > sink_headroom,
		"skirt %.1f vs sink %.1f" % [TerrainHeightField.SKIRT_DROP_M, sink_headroom])


func _test_sculpt_ops_v2() -> void:
	var flat := func(_x: float, _z: float) -> float: return 100.0

	# Falloff: 1 at centre, 0 at/after edge, monotonic.
	_check("sculptops falloff centre", _approx(TerrainSculptOps.falloff(0.0, 10.0, 0.5), 1.0, 1e-4))
	_check("sculptops falloff edge", _approx(TerrainSculptOps.falloff(10.0, 10.0, 0.5), 0.0, 1e-4))

	# Raise brush lifts the centre by ~amount and tapers to 0 at the rim.
	var t := TerrainEditTiles.new()
	TerrainSculptOps.raise_lower_brush(t, Vector2(0, 0), 12.0, 4.0, 0.5)
	_check("sculptops raise centre", _approx(t.sample_delta(0, 0), 4.0, 0.2),
		"got %f" % t.sample_delta(0, 0))
	_check("sculptops raise outside ~0", absf(t.sample_delta(20, 0)) < 0.05,
		"got %f" % t.sample_delta(20, 0))

	# Level polygon drives the interior surface to the target Y (delta = target-base).
	var poly := PackedVector2Array([
		Vector2(-15, -15), Vector2(15, -15), Vector2(15, 15), Vector2(-15, 15)])
	var t2 := TerrainEditTiles.new()
	TerrainSculptOps.level_polygon(t2, poly, 108.0, 6.0, flat)
	var surf := 100.0 + t2.sample_delta(0, 0)
	_check("sculptops level interior hits target", _approx(surf, 108.0, 0.05),
		"got %f" % surf)
	# Feather: a point ~3 m outside is partway between target and base.
	var edge := 100.0 + t2.sample_delta(18.0, 0.0)
	_check("sculptops level feathers out", edge > 100.5 and edge < 107.9,
		"got %f" % edge)
	# Well outside the feather is untouched.
	_check("sculptops level leaves far ground", absf(t2.sample_delta(40.0, 0.0)) < 0.05)

	# Flatten brush eases toward target without overshoot in one pass.
	var t3 := TerrainEditTiles.new()
	TerrainSculptOps.flatten_brush(t3, Vector2(0, 0), 10.0, 90.0, 1.0, flat, 0.9)
	var fs := 100.0 + t3.sample_delta(0, 0)
	_check("sculptops flatten toward target", fs < 100.0 and fs >= 89.9, "got %f" % fs)

	# Ramp grades from ya to yb along its axis.
	var t4 := TerrainEditTiles.new()
	TerrainSculptOps.ramp(t4, Vector2(-20, 0), Vector2(20, 0), 100.0, 120.0, 8.0, flat)
	var mid := 100.0 + t4.sample_delta(0.0, 0.0)
	_check("sculptops ramp midpoint", _approx(mid, 110.0, 1.0), "got %f" % mid)
	var near_end := 100.0 + t4.sample_delta(19.0, 0.0)
	_check("sculptops ramp rises to end", near_end > 115.0, "got %f" % near_end)

	# Carve basin: flat floor at rim-depth, sloped banks, rim returned for fill.
	var poly2 := PackedVector2Array([
		Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20)])
	var t6 := TerrainEditTiles.new()
	var rim := TerrainSculptOps.carve_basin(t6, poly2, 3.0, 2.0, flat)
	_check("sculptops basin rim", _approx(rim, 100.0, 0.01), "got %f" % rim)
	var floor_y := 100.0 + t6.sample_delta(0, 0)
	_check("sculptops basin floor depth", _approx(floor_y, 97.0, 0.2), "got %f" % floor_y)
	# A point near the rim is shallower than the floor.
	var bankpt := 100.0 + t6.sample_delta(18.0, 0.0)
	_check("sculptops basin bank shallower", bankpt > floor_y + 0.3 and bankpt <= 100.01,
		"got %f" % bankpt)
	# Outside the polygon is untouched.
	_check("sculptops basin leaves exterior", absf(t6.sample_delta(40.0, 0.0)) < 0.05)

	# Volume estimate: a pure raise gives fill>0/cut≈0; a cut gives the reverse.
	var t7 := TerrainEditTiles.new()
	TerrainSculptOps.raise_lower_brush(t7, Vector2(0, 0), 20.0, 5.0, 0.5)
	var vol := t7.volume_estimate()
	_check("volume fill positive", float(vol.get("fill_m3", 0.0)) > 0.0,
		"got %f" % float(vol.get("fill_m3", 0.0)))
	_check("volume cut ~zero on raise", float(vol.get("cut_m3", 0.0)) < 1.0,
		"got %f" % float(vol.get("cut_m3", 0.0)))
	var t8 := TerrainEditTiles.new()
	TerrainSculptOps.raise_lower_brush(t8, Vector2(0, 0), 20.0, -5.0, 0.5)
	var vol2 := t8.volume_estimate()
	_check("volume cut positive on lower", float(vol2.get("cut_m3", 0.0)) > 0.0,
		"got %f" % float(vol2.get("cut_m3", 0.0)))
	_check("volume net negative on lower", float(vol2.get("net_m3", 0.0)) < 0.0)

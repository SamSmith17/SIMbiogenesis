extends SceneTree

## Headless self-test for VegLodPolicy (Overhaul v2 LOD): the budget-aware
## tree detail distance that replaced the SoI rings + large-map force_far
## flattening. Offline, deterministic.
## Run with:
##   godot --headless --path . --script vegetation/veg_lod_policy_selftest.gd

var _failures := 0
var _checks := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _initialize() -> void:
	_test_sparse_keeps_requested()
	_test_dense_shrinks()
	_test_never_below_floor()
	_test_chunk_counts()
	_test_chain_parsing()
	_test_chain_bands()
	_test_chain_resolution()
	_test_far_tier_reach()
	if _failures == 0:
		print("VEG LOD POLICY SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG LOD POLICY SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _test_sparse_keeps_requested() -> void:
	# A handful of light chunks: the user's requested range is affordable.
	var counts := {Vector2i(0, 0): 40, Vector2i(4, 4): 30, Vector2i(-3, 2): 25}
	var d := VegLodPolicy.effective_detail_distance(counts, 220.0, 1500)
	_check("sparse map keeps the requested distance", is_equal_approx(d, 220.0),
		"got %.1f" % d)
	_check("empty map keeps the requested distance",
		is_equal_approx(VegLodPolicy.effective_detail_distance({}, 400.0, 100), 400.0))


func _test_dense_shrinks() -> void:
	# A 10x10 block of 256 m chunks at 200 trees each = 20k trees. A 400 m
	# request would put thousands of full meshes in the near set; the policy
	# must shrink until the worst-case fits the budget.
	var counts := {}
	for x in 10:
		for z in 10:
			counts[Vector2i(x, z)] = 200
	var d := VegLodPolicy.effective_detail_distance(counts, 400.0, 800)
	_check("dense map shrinks the distance", d < 400.0, "got %.1f" % d)
	# ...and the shrunk distance really is affordable: worst-case near set at
	# distance d must be <= budget (re-derive with the policy's own metric).
	var worst := 0
	var reach := d + 256.0 * 1.42
	for a in counts:
		var total := 0
		var ca := (Vector2(Vector2i(a)) + Vector2(0.5, 0.5)) * 256.0
		for b in counts:
			var cb := (Vector2(Vector2i(b)) + Vector2(0.5, 0.5)) * 256.0
			if ca.distance_to(cb) <= reach:
				total += int(counts[b])
		worst = maxi(worst, total)
	# The floor may win over the budget (trees within arm's reach are always
	# real): the distance either fits the budget OR sits at the floor.
	_check("shrunk distance fits the budget (or bottomed at the floor)",
		worst <= 800 or is_equal_approx(d, VegLodPolicy.MIN_DETAIL_M),
		"worst near-set %d at %.1f m" % [worst, d])
	# A bigger budget must never yield a SHORTER distance.
	var d_big := VegLodPolicy.effective_detail_distance(counts, 400.0, 4000)
	_check("bigger budget never shortens", d_big >= d,
		"%.1f < %.1f" % [d_big, d])


func _test_never_below_floor() -> void:
	# Absurd density: the floor holds so close-range trees are always real.
	var counts := {Vector2i(0, 0): 100000}
	var d := VegLodPolicy.effective_detail_distance(counts, 300.0, 100)
	_check("distance never drops below the floor", d >= VegLodPolicy.MIN_DETAIL_M - 0.01,
		"got %.1f" % d)


func _test_chunk_counts() -> void:
	var bulk := {
		"deciduous": [{"x": 10.0, "z": 10.0}, {"x": 300.0, "z": 10.0}],
		"spruce": [{"x": 20.0, "z": 20.0}],
		"shrub": [{"x": 30.0, "z": 30.0}],       # not a tree family
		"grass_lawn": [{"x": 40.0, "z": 40.0}],  # not a tree family
	}
	var counts := VegLodPolicy.chunk_tree_counts([bulk])
	_check("trees counted per chunk", int(counts.get(Vector2i(0, 0), 0)) == 2,
		"got %s" % str(counts))
	_check("second chunk counted", int(counts.get(Vector2i(1, 0), 0)) == 1)
	var total := 0
	for k in counts:
		total += int(counts[k])
	_check("grass/shrub never counted", total == 3, "total %d" % total)


## --- Overhaul v2.1: configurable LOD ladder ---------------------------------

func _test_chain_parsing() -> void:
	_check("default parses", VegLodPolicy.parse_chain("mesh,impostor")
			== ["mesh", "impostor"])
	_check("three-step parses", VegLodPolicy.parse_chain("mesh,photocard,impostor")
			== ["mesh", "photocard", "impostor"])
	_check("photocard-only parses", VegLodPolicy.parse_chain("photocard")
			== ["photocard"])
	_check("whitespace + case tolerated",
			VegLodPolicy.parse_chain(" Mesh , IMPOSTOR ") == ["mesh", "impostor"])
	_check("unknown tokens dropped",
			VegLodPolicy.parse_chain("mesh,hologram,impostor") == ["mesh", "impostor"])
	_check("duplicates keep first position",
			VegLodPolicy.parse_chain("mesh,impostor,mesh") == ["mesh", "impostor"])
	_check("empty falls back to default",
			VegLodPolicy.parse_chain("") == ["mesh", "impostor"])
	_check("garbage falls back to default",
			VegLodPolicy.parse_chain("nonsense") == ["mesh", "impostor"])
	# User-chosen ORDER is preserved (the ladder is theirs, not canonicalized).
	_check("order preserved", VegLodPolicy.parse_chain("impostor,mesh")
			== ["impostor", "mesh"])


func _test_chain_bands() -> void:
	# The default two-band chain reproduces the shipped model exactly:
	# mesh 0..detail, impostor detail..cull.
	var b2: Array = VegLodPolicy.chain_bands(["mesh", "impostor"], 220.0, 700.0, 1400.0)
	_check("two bands", b2.size() == 2, str(b2))
	_check("mesh band 0..detail",
			str((b2[0] as Dictionary)["rep"]) == "mesh"
			and is_equal_approx(float((b2[0] as Dictionary)["begin_m"]), 0.0)
			and is_equal_approx(float((b2[0] as Dictionary)["end_m"]), 220.0))
	_check("impostor band detail..cull",
			str((b2[1] as Dictionary)["rep"]) == "impostor"
			and is_equal_approx(float((b2[1] as Dictionary)["begin_m"]), 220.0)
			and is_equal_approx(float((b2[1] as Dictionary)["end_m"]), 1400.0))
	# Three bands: photocard in the middle.
	var b3: Array = VegLodPolicy.chain_bands(
			["mesh", "photocard", "impostor"], 220.0, 700.0, 1400.0)
	_check("three bands", b3.size() == 3, str(b3))
	_check("photocard band detail..photo",
			str((b3[1] as Dictionary)["rep"]) == "photocard"
			and is_equal_approx(float((b3[1] as Dictionary)["begin_m"]), 220.0)
			and is_equal_approx(float((b3[1] as Dictionary)["end_m"]), 700.0))
	_check("last band always reaches the cull end",
			is_equal_approx(float((b3[2] as Dictionary)["end_m"]), 1400.0))
	# Single band covers everything regardless of the distance knobs.
	var b1: Array = VegLodPolicy.chain_bands(["photocard"], 220.0, 700.0, 1400.0)
	_check("single band full range", b1.size() == 1
			and is_equal_approx(float((b1[0] as Dictionary)["begin_m"]), 0.0)
			and is_equal_approx(float((b1[0] as Dictionary)["end_m"]), 1400.0))
	# Detail ≥ cull collapses a two-band chain to one full-range mesh band —
	# the old "single batch" special case.
	var bc: Array = VegLodPolicy.chain_bands(["mesh", "impostor"], 2000.0, 700.0, 1400.0)
	_check("detail past cull collapses to one band", bc.size() == 1
			and str((bc[0] as Dictionary)["rep"]) == "mesh"
			and is_equal_approx(float((bc[0] as Dictionary)["end_m"]), 1400.0))
	# Photocard boundary is forced past the detail boundary.
	var bo: Array = VegLodPolicy.chain_bands(
			["mesh", "photocard", "impostor"], 500.0, 300.0, 1400.0)
	_check("photocard boundary forced past detail",
			float((bo[1] as Dictionary)["end_m"]) > float((bo[1] as Dictionary)["begin_m"]))
	# Bands tile: each begins where the previous ended.
	var prev_end := 0.0
	for band_v in b3:
		var band: Dictionary = band_v
		_check("bands tile continuously",
				is_equal_approx(float(band["begin_m"]), prev_end))
		prev_end = float(band["end_m"])


## The card factory's chain resolution: photocard entries survive only when a
## texture exists; non-canopy families are single-band mesh.
func _test_chain_resolution() -> void:
	# pine/spruce/fir/cedar photocards ship in assets/vegetation/photocards/.
	var with_photo := VegetationCardFactory.lod_chain("pine",
			{"pine_detail_chain": "photocard,impostor"})
	_check("pine photocard chain honoured", with_photo == ["photocard", "impostor"],
			str(with_photo))
	# The default when the key is absent.
	_check("absent key yields the default chain",
			VegetationCardFactory.lod_chain("pine", {}) == ["mesh", "impostor"])
	# A species with no photocard drops the entry rather than rendering nothing.
	var no_photo := VegetationCardFactory.lod_chain("deciduous",
			{"deciduous_detail_chain": "photocard,impostor"})
	_check("photocard dropped when no texture ships", not ("photocard" in no_photo),
			str(no_photo))
	_check("chain never empties", no_photo.size() >= 1)
	# Non-canopy families are single-band mesh (palms photocard via Phase 5).
	_check("shrub is single-band mesh",
			VegetationCardFactory.lod_chain("shrub", {}) == ["mesh"])
	# A photocard-first chain makes the NEAR mesh the photocard — this is what
	# the impostor baker bakes from, so the far silhouette matches the card.
	var near := VegetationCardFactory.mesh_for_canopy_lod("pine",
			{"pine_detail_chain": "photocard,impostor"},
			VegetationCardFactory.CanopyLodTier.NEAR)
	_check("photocard-first NEAR mesh is a photocard (1 surface)",
			near != null and near.get_surface_count() == 1,
			"surfaces=%d" % (near.get_surface_count() if near != null else -1))
	var near_default := VegetationCardFactory.mesh_for_canopy_lod("pine", {},
			VegetationCardFactory.CanopyLodTier.NEAR)
	_check("default NEAR mesh keeps trunk+foliage surfaces",
			near_default != null and near_default.get_surface_count() >= 2)
	# The bake key must SEE the chain (a photocard-first bake and a mesh bake
	# may not collide — the atlas silhouettes differ).
	var k_default := VegImpostorBaker.bake_key("pine", {})
	var k_photo := VegImpostorBaker.bake_key("pine",
			{"pine_detail_chain": "photocard,impostor"})
	_check("bake key includes the chain", k_default != k_photo,
			"%s == %s" % [k_default, k_photo])


## The Globe lens / snowglobe orbit up to 4.5 x the SoI radius out, and a
## visibility range is measured to each 256 m chunk's centre: a far tier that
## stopped at the first-person cull end (480 m on large maps) blinked whole
## chunks in and out. The far tier now reaches KEY_FAR_TIER_END; the mesh
## tier must NOT (it is the prim budget), and the handoff fade grows with
## distance so one orbit zoom notch cannot jump across it.
func _test_far_tier_reach() -> void:
	var chain := ["mesh", "impostor"]
	_check("far tier takes the globe reach",
		is_equal_approx(VegLodPolicy.far_tier_end(chain, 480.0,
			{VegLodPolicy.KEY_FAR_TIER_END: 1340.0}), 1340.0))
	_check("far tier never shorter than the cull end",
		is_equal_approx(VegLodPolicy.far_tier_end(chain, 1800.0,
			{VegLodPolicy.KEY_FAR_TIER_END: 1340.0}), 1800.0))
	_check("no reach key = the cull end",
		is_equal_approx(VegLodPolicy.far_tier_end(chain, 480.0, {}), 480.0))
	_check("a mesh-only chain keeps the cull end (prim budget)",
		is_equal_approx(VegLodPolicy.far_tier_end(["mesh"], 480.0,
			{VegLodPolicy.KEY_FAR_TIER_END: 1340.0}), 480.0))
	_check("fade band floor", is_equal_approx(VegLodPolicy.fade_margin_for(60.0), 24.0))
	_check("fade band grows with distance",
		VegLodPolicy.fade_margin_for(400.0) > VegLodPolicy.fade_margin_for(150.0))
	_check("fade band capped", VegLodPolicy.fade_margin_for(5000.0) <= VegLodPolicy.MAX_FADE_M)
	# A real build: headless never bakes, so the far tier is the crossed-card
	# stand-in — its range is the same band the impostor would get.
	var root := Node3D.new()
	var settings: Dictionary = VegetationStyleConfig.defaults()
	settings["tree_detail_eff_m"] = 150.0
	settings[VegLodPolicy.KEY_FAR_TIER_END] = 1340.0
	var resolved := VegSpeciesCatalog.settings_with_variant("fir", settings,
		VegetationCardFactory.SPECS)
	var recs := [{"x": 10.0, "z": 10.0, "yaw": 0.0, "scale": 1.0}]
	VegetationRuntime._build_canopy_lod_bulk_batches(root, "fir", recs,
		func(_x: float, _z: float) -> float: return 0.0, false, resolved, 480.0)
	var near_end := -1.0
	var far_end := -1.0
	var near_end_margin := -1.0
	var far_begin_margin := -1.0
	for c in root.get_children():
		var mi := c as GeometryInstance3D
		if mi == null:
			continue
		if mi.visibility_range_begin <= 0.0:
			near_end = mi.visibility_range_end
			near_end_margin = mi.visibility_range_end_margin
		else:
			far_end = mi.visibility_range_end
			far_begin_margin = mi.visibility_range_begin_margin
	_check("built mesh tier ends at the detail distance", is_equal_approx(near_end, 150.0),
		"got %.1f" % near_end)
	_check("built far tier reaches the globe", is_equal_approx(far_end, 1340.0),
		"got %.1f" % far_end)
	_check("handoff fade bands match on both sides",
		is_equal_approx(near_end_margin, far_begin_margin) and near_end_margin > 0.0,
		"%.1f vs %.1f" % [near_end_margin, far_begin_margin])
	root.free()

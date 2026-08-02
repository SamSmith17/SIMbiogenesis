extends SceneTree

## Headless self-test for the Phase 3 static SoI-centred detail rings.
## Pure / offline — ring math + build-time tier assignment over a synthetic
## layer (no network, no impostor bake; the bake verifies windowed via
## --capture=veg).
## Run with:
##   godot --headless --path . --script vegetation/veg_tier_ring_selftest.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_ring_math()
	_test_ring_settings_gate()
	_test_runtime_tier_assignment()
	_test_force_far_near_ring_exempt()
	if _failures == 0:
		print("VEG TIER RING SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG TIER RING SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_ring_math() -> void:
	var c := Vector2.ZERO
	# Chunk (0,0) spans 0..256 — closest point to origin is the corner (0,0).
	_check("chunk containing centre is NEAR",
		VegTierRings.ring_for_chunk(0, 0, 256.0, c, 250.0, 700.0) == VegTierRings.RING_NEAR)
	_check("negative chunk touching centre is NEAR",
		VegTierRings.ring_for_chunk(-1, -1, 256.0, c, 250.0, 700.0) == VegTierRings.RING_NEAR)
	# Chunk (1,0): closest point x=256 > 250 → MID.
	_check("chunk just past near radius is MID",
		VegTierRings.ring_for_chunk(1, 0, 256.0, c, 250.0, 700.0) == VegTierRings.RING_MID)
	# Chunk (3,0): closest point x=768 > 700 → OUTER.
	_check("chunk past mid radius is OUTER",
		VegTierRings.ring_for_chunk(3, 0, 256.0, c, 250.0, 700.0) == VegTierRings.RING_OUTER)
	# Boundary chunk errs toward detail: closest point rule — chunk (2,0)
	# spans 512..768, closest 512 ≤ 700 → MID even though its centre (640) is
	# also ≤ 700; chunk (2,2) corner at (512,512) → dist 724 → OUTER.
	_check("diagonal chunk past mid is OUTER",
		VegTierRings.ring_for_chunk(2, 2, 256.0, c, 250.0, 700.0) == VegTierRings.RING_OUTER)
	# Off-centre ring: centre far from origin moves the NEAR ring with it.
	var c2 := Vector2(2000.0, 0.0)
	_check("off-centre: origin chunk is OUTER",
		VegTierRings.ring_for_chunk(0, 0, 256.0, c2, 250.0, 700.0) == VegTierRings.RING_OUTER)
	_check("off-centre: chunk at the pin is NEAR",
		VegTierRings.ring_for_chunk(7, 0, 256.0, c2, 250.0, 700.0) == VegTierRings.RING_NEAR)
	# mid clamped to at least near.
	var p := VegTierRings.params_from_settings({"veg_near_ring_m": 500.0, "veg_mid_ring_m": 100.0})
	_check("mid radius clamped to >= near", float(p["mid_m"]) >= float(p["near_m"]))


func _test_ring_settings_gate() -> void:
	_check("disabled -> everything NEAR",
		VegTierRings.ring_for_chunk_settings(9, 9, 256.0,
			{"veg_tier_rings_enabled": false}) == VegTierRings.RING_NEAR)
	_check("defaults enable rings",
		VegTierRings.enabled(VegetationStyleConfig.defaults()))
	var s := {"veg_ring_center_x": 0.0, "veg_ring_center_z": 0.0,
		"veg_near_ring_m": 250.0, "veg_mid_ring_m": 700.0}
	_check("settings-driven OUTER",
		VegTierRings.ring_for_chunk_settings(4, 4, 256.0, s) == VegTierRings.RING_OUTER)


## Build a manual layer with trees in the core chunk and in a far chunk:
## the core chunk must carry the leaf-tier PAIR (2 MMIs), the far chunk a
## single FAR-card MMI.
func _test_runtime_tier_assignment() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := VegetationLayer.create_empty()
	layer.add_bulk("deciduous", 10.0, 10.0, 0.0, 1.0)      # chunk (0,0) — NEAR ring
	layer.add_bulk("deciduous", 1500.0, 1500.0, 0.0, 1.0)  # chunk (5,5) — OUTER
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var settings := {
		"veg_tier_rings_enabled": true,
		"veg_ring_center_x": 0.0, "veg_ring_center_z": 0.0,
		"veg_near_ring_m": 250.0, "veg_mid_ring_m": 700.0,
		"deciduous_leaf_shells_enabled": true, "deciduous_leaf_lod_enabled": true,
	}
	VegetationRuntime.rebuild(terrain, layer, ground, false, settings)
	var root := terrain.get_node_or_null("Vegetation")
	var near_mms := 0
	var far_mms := 0
	var near_has_leaf_tier := false
	var outer_surfaces := -1
	for child in root.get_children():
		if not (child is MultiMeshInstance3D):
			continue
		var n := String(child.name)
		if n.ends_with("_0_0"):
			near_mms += 1
			# Canopy pair names carry the tier: Bulk_deciduous_<tier>_0_0.
			if n.contains("_%d_" % VegetationCardFactory.CanopyLodTier.NEAR):
				near_has_leaf_tier = true
		elif n.ends_with("_5_5"):
			far_mms += 1
			outer_surfaces = (child as MultiMeshInstance3D).multimesh.mesh.get_surface_count()
	_check("core chunk builds the LOD pair", near_mms == 2, "got %d MMs" % near_mms)
	_check("core chunk includes the leaf NEAR tier", near_has_leaf_tier)
	_check("outer chunk builds a single MM", far_mms == 1, "got %d MMs" % far_mms)
	# FAR card mesh = 2 surfaces (bark + foliage cards); the leaf-shell NEAR
	# mesh has 3 (bark + shadow proxy + shells).
	_check("outer chunk uses the FAR card mesh", outer_surfaces == 2,
		"got %d surfaces" % outer_surfaces)
	terrain.queue_free()


## auto_force_far_canopy (large maps) must NOT flatten the SoI NEAR ring —
## the static core ring is exempt by design.
func _test_force_far_near_ring_exempt() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	var layer := AutoVegetationLayer.create_empty()
	layer.add_bulk("deciduous", 10.0, 10.0, 0.0, 1.0, 12.0)      # NEAR ring
	layer.add_bulk("deciduous", 1500.0, 1500.0, 0.0, 1.0, 12.0)  # OUTER
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var settings := {
		"auto_force_far_canopy": true,
		"veg_tier_rings_enabled": true,
		"veg_ring_center_x": 0.0, "veg_ring_center_z": 0.0,
		"veg_near_ring_m": 250.0, "veg_mid_ring_m": 700.0,
		"deciduous_leaf_shells_enabled": true, "deciduous_leaf_lod_enabled": true,
	}
	AutoVegetationRuntime.rebuild(terrain, layer, ground, settings)
	var root := terrain.get_node_or_null(AutoVegetationRuntime.ROOT_NAME)
	var near_mms := 0
	var far_mms := 0
	for child in root.get_children():
		if not (child is MultiMeshInstance3D):
			continue
		var n := String(child.name)
		if n.ends_with("_0_0"):
			near_mms += 1
		elif n.ends_with("_5_5"):
			far_mms += 1
	_check("force_far keeps the leaf pair in the SoI core", near_mms == 2,
		"got %d MMs" % near_mms)
	_check("force_far flattens outer chunks to one MM", far_mms == 1,
		"got %d MMs" % far_mms)
	terrain.queue_free()

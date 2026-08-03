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

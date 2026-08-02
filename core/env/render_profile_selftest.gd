extends SceneTree

## Offline deterministic selftest for RenderProfile (core/env/render_profile.gd).
##
## Run: Godot.exe.exe --headless --path . --script core/env/render_profile_selftest.gd
##
## These tables decide what the game actually renders with: project.godot only
## carries the HIGH baseline, and main.gd overrides atlas size, soft-shadow
## quality and TAA at runtime from whichever preset is selected. Pinning them
## here means a preset cannot silently drift, and the "which quality level is
## actually cheaper?" question has an offline answer.

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_quality_names()
	_test_graphics_profiles()
	_test_graphics_monotonic()
	_test_shadow_profiles()
	_test_shadow_monotonic()
	_test_render_scale_roundtrip()
	_test_veg_profiles()
	_test_veg_monotonic()
	if _fails == 0:
		print("RENDER PROFILE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("RENDER PROFILE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_quality_names() -> void:
	_check("low name", RenderProfile.quality_name(RenderProfile.QUALITY_LOW) == "Low")
	_check("medium name", RenderProfile.quality_name(RenderProfile.QUALITY_MEDIUM) == "Medium")
	_check("high name", RenderProfile.quality_name(RenderProfile.QUALITY_HIGH) == "High")
	_check("unknown name falls back to High", RenderProfile.quality_name(99) == "High")


## Values pinned against what main.gd applied before the extraction, so the
## split is provably behaviour-preserving.
func _test_graphics_profiles() -> void:
	var lo := RenderProfile.graphics_profile(RenderProfile.QUALITY_LOW)
	_check("low atlas", int(lo["atlas_size"]) == 1024)
	_check("low soft", int(lo["soft_quality"]) == RenderingServer.SHADOW_QUALITY_SOFT_LOW)
	_check("low disables TAA", not bool(lo["taa"]))

	var mid := RenderProfile.graphics_profile(RenderProfile.QUALITY_MEDIUM)
	_check("medium atlas", int(mid["atlas_size"]) == 1536)
	_check("medium soft", int(mid["soft_quality"]) == RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	_check("medium enables TAA", bool(mid["taa"]))

	var hi := RenderProfile.graphics_profile(RenderProfile.QUALITY_HIGH)
	_check("high atlas matches project.godot baseline", int(hi["atlas_size"]) == 2048)
	_check("high soft", int(hi["soft_quality"]) == RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	_check("high enables TAA", bool(hi["taa"]))

	# A corrupt or future saved index must degrade to "looks right", not to an
	# empty dict that would leave every knob unset.
	var bad := RenderProfile.graphics_profile(99)
	_check("unknown level falls back to HIGH, not empty", bad == hi)
	_check("negative level falls back to HIGH",
		RenderProfile.graphics_profile(-1) == hi)


## The presets have to be ordered as advertised, or the quality dropdown is
## lying to the player.
func _test_graphics_monotonic() -> void:
	var lo := RenderProfile.graphics_profile(RenderProfile.QUALITY_LOW)
	var mid := RenderProfile.graphics_profile(RenderProfile.QUALITY_MEDIUM)
	var hi := RenderProfile.graphics_profile(RenderProfile.QUALITY_HIGH)
	_check("atlas size increases with quality",
		int(lo["atlas_size"]) < int(mid["atlas_size"])
			and int(mid["atlas_size"]) < int(hi["atlas_size"]))
	_check("soft-shadow quality increases with quality",
		int(lo["soft_quality"]) < int(mid["soft_quality"])
			and int(mid["soft_quality"]) <= int(hi["soft_quality"]))


func _test_shadow_profiles() -> void:
	for level in 4:
		var p := RenderProfile.shadow_profile(level)
		_check("shadow level %d is defined" % level, not p.is_empty())
		for key in ["mode", "max_distance", "blur", "bias", "normal_bias",
				"split_1", "split_2", "split_3", "pancake", "moon_distance_scale"]:
			_check("shadow level %d has %s" % [level, key], p.has(key))
		# Cascade splits are fractions of max_distance and must stay ordered, or
		# the cascades overlap and shadows band.
		_check("shadow level %d splits ascend" % level,
			float(p["split_1"]) < float(p["split_2"])
				and float(p["split_2"]) < float(p["split_3"]))
		_check("shadow level %d splits are fractions" % level,
			float(p["split_1"]) > 0.0 and float(p["split_3"]) < 1.0)

	# Unknown levels return {} on purpose: the caller applies onto LIVE lights,
	# so doing nothing beats forcing a preset nobody asked for. This is
	# deliberately different from graphics_profile's fallback.
	_check("unknown shadow level is empty", RenderProfile.shadow_profile(99).is_empty())
	_check("negative shadow level is empty", RenderProfile.shadow_profile(-1).is_empty())


func _test_shadow_monotonic() -> void:
	var prev_dist := -1.0
	var prev_blur := 1.0e9
	for level in 4:
		var p := RenderProfile.shadow_profile(level)
		var d := float(p["max_distance"])
		var b := float(p["blur"])
		_check("shadow distance grows at level %d" % level, d > prev_dist,
			"%.1f is not > %.1f" % [d, prev_dist])
		# Higher quality = sharper, so blur falls as the level rises.
		_check("shadow blur shrinks at level %d" % level, b < prev_blur,
			"%.3f is not < %.3f" % [b, prev_blur])
		prev_dist = d
		prev_blur = b
	# The two cheap levels use 2 cascades, the two expensive ones 4 — that split
	# is the main cost step in the table.
	_check("levels 0-1 use 2 splits",
		int(RenderProfile.shadow_profile(0)["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			and int(RenderProfile.shadow_profile(1)["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)
	_check("levels 2-3 use 4 splits",
		int(RenderProfile.shadow_profile(2)["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			and int(RenderProfile.shadow_profile(3)["mode"]) == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)


## Round-trips through the REAL config file, then restores whatever was there —
## a selftest must not leave the player's render scale changed.
func _test_render_scale_roundtrip() -> void:
	var sentinel := -12345.0
	var original := RenderProfile.load_render_scale(sentinel)
	RenderProfile.save_render_scale(0.77)
	_check("render scale round-trips",
		is_equal_approx(RenderProfile.load_render_scale(1.0), 0.77))
	_check("fallback is ignored once a value exists",
		not is_equal_approx(RenderProfile.load_render_scale(0.25), 0.25))
	if is_equal_approx(original, sentinel):
		# Nothing was persisted before; put it back to the shipped default so the
		# test does not invent a setting the player never chose.
		RenderProfile.save_render_scale(1.0)
	else:
		RenderProfile.save_render_scale(original)
	_check("original render scale restored",
		is_equal_approx(RenderProfile.load_render_scale(1.0),
			1.0 if is_equal_approx(original, sentinel) else original))


## Veg overhaul Phase 4: every veg tier value pinned. HIGH must equal the
## pre-Phase-4 defaults exactly (an untouched install renders identically),
## and HIGH's large-map overrides must equal the old hardcoded thinning.
func _test_veg_profiles() -> void:
	_check("ultra name", RenderProfile.quality_name(RenderProfile.QUALITY_ULTRA) == "Ultra")
	var ug := RenderProfile.graphics_profile(RenderProfile.QUALITY_ULTRA)
	_check("ultra atlas", int(ug["atlas_size"]) == 4096)
	_check("ultra soft", int(ug["soft_quality"]) == RenderingServer.SHADOW_QUALITY_SOFT_ULTRA)
	_check("ultra enables TAA", bool(ug["taa"]))

	var hi := RenderProfile.veg_profile(RenderProfile.QUALITY_HIGH)
	var hs: Dictionary = hi["style"]
	var defaults := VegetationStyleConfig.defaults()
	for pair in [["veg_near_ring_m", 250.0], ["veg_mid_ring_m", 700.0],
			["deciduous_leaf_shell_count", 7.0], ["grass_detail_radius_m", 500.0],
			["grass_visibility_end_m", 520.0], ["auto_visibility_end_m", 1200.0]]:
		_check("HIGH veg %s pinned" % pair[0],
			is_equal_approx(float(hs[pair[0]]), float(pair[1])))
		_check("HIGH veg %s == style defaults (behaviour-preserving)" % pair[0],
			is_equal_approx(float(hs[pair[0]]), float(defaults[pair[0]])))
	_check("HIGH tree cap pinned", int(hs["auto_max_tree_instances"]) == 24000)
	_check("HIGH grass cap pinned", int(hs["auto_max_grass_instances"]) == 120000)
	var hl: Dictionary = hi["style_large"]
	_check("HIGH large force_far (old hardcode)", bool(hl["auto_force_far_canopy"]))
	_check("HIGH large tree cap == old hardcode", int(hl["auto_max_tree_instances"]) == 4000)
	_check("HIGH large grass cap == old hardcode", int(hl["auto_max_grass_instances"]) == 24000)
	_check("HIGH large vis == old hardcode", is_equal_approx(float(hl["auto_visibility_end_m"]), 480.0))
	_check("HIGH large density == old hardcode", is_equal_approx(float(hl["auto_density_scale"]), 0.35))
	_check("HIGH no veg shadows", not bool(hi["veg_shadows"]))

	var ultra := RenderProfile.veg_profile(RenderProfile.QUALITY_ULTRA)
	_check("ULTRA veg shadows on", bool(ultra["veg_shadows"]))
	_check("ULTRA large map keeps leaf tiers",
		not bool((ultra["style_large"] as Dictionary)["auto_force_far_canopy"]))
	var lo := RenderProfile.veg_profile(RenderProfile.QUALITY_LOW)
	_check("LOW shells pinned", is_equal_approx(float((lo["style"] as Dictionary)["deciduous_leaf_shell_count"]), 3.0))
	_check("LOW large force_far", bool((lo["style_large"] as Dictionary)["auto_force_far_canopy"]))

	_check("unknown veg level falls back to HIGH",
		RenderProfile.veg_profile(99) == hi)
	_check("negative veg level falls back to HIGH",
		RenderProfile.veg_profile(-1) == hi)


## Every scaling knob must be non-decreasing Low -> Medium -> High -> Ultra,
## and each tier's large-map budget must never exceed its normal budget.
func _test_veg_monotonic() -> void:
	var order := [RenderProfile.QUALITY_LOW, RenderProfile.QUALITY_MEDIUM,
		RenderProfile.QUALITY_HIGH, RenderProfile.QUALITY_ULTRA]
	var keys := ["veg_near_ring_m", "veg_mid_ring_m", "deciduous_leaf_shell_count",
		"auto_max_tree_instances", "auto_max_grass_instances",
		"grass_detail_radius_m", "grass_visibility_end_m", "auto_visibility_end_m"]
	for i in range(1, order.size()):
		var prev: Dictionary = RenderProfile.veg_profile(order[i - 1])["style"]
		var cur: Dictionary = RenderProfile.veg_profile(order[i])["style"]
		for k in keys:
			_check("%s non-decreasing at tier %d" % [k, i],
				float(cur[k]) >= float(prev[k]),
				"%s -> %s" % [str(prev[k]), str(cur[k])])
	for q in order:
		var p := RenderProfile.veg_profile(q)
		var s: Dictionary = p["style"]
		var l: Dictionary = p["style_large"]
		for k in ["auto_max_tree_instances", "auto_max_grass_instances",
				"auto_visibility_end_m", "grass_visibility_end_m"]:
			_check("large-map %s <= normal at q%d" % [k, q],
				float(l[k]) <= float(s[k]),
				"%s > %s" % [str(l[k]), str(s[k])])
		_check("rings ordered at q%d" % q,
			float(s["veg_mid_ring_m"]) >= float(s["veg_near_ring_m"]))

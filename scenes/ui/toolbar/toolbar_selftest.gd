extends SceneTree

## Offline selftest for the unified edit toolbar's data layer:
## EditToolbarState (scenes/ui/toolbar/toolbar_state.gd) and
## ShapeGestureController (shape_gesture_controller.gd).
##
## Run: Godot.exe.exe --headless --path . --script scenes/ui/toolbar/toolbar_selftest.gd
##
## Why this exists: the toolbar replaces two modal docks whose parameters were
## GLOBAL — tuning Smooth's radius silently moved Raise's. Per-tool isolation is
## the headline fix and it is pure data, so it is asserted here rather than by
## clicking. The gesture ladder (circle/rect/lasso/polygon + the Esc peel) is
## likewise pure logic over world coordinates, deliberately kept free of
## viewport/ray dependencies so it can be driven offline.
##
## Note the file name: ui_compile_selftest's sweep SKIPS *_selftest.gd, so this
## does not recurse into that suite.
##
## _initialize (not _init) so autoloads are registered first — VegetationPaint
## and friends resolve the same way they do in game.

const StateScript := preload("res://scenes/ui/toolbar/toolbar_state.gd")
const GestureScript := preload("res://scenes/ui/toolbar/shape_gesture_controller.gd")

## Guard against a Godot runtime error aborting a test function early while the
## suite still prints PASS — the trap veg_dock_state_selftest documents.
## Count of every check ABOVE the guard itself. Bump it when adding checks.
const EXPECTED_CHECKS := 612   # +42: the veg Detect tool (10 registry + 8 params × 4)

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_registry_integrity()
	_test_param_isolation()
	_test_shape_memory()
	_test_option_specs()
	_test_veg_families_match_preset_enum()
	_test_veg_identity()
	_test_camp_styles()
	_test_placement_state()
	_test_gesture_path()
	_test_config_round_trip()
	_test_config_robustness()
	_test_file_round_trip()
	_test_gesture_shapes()
	_test_gesture_polygon()
	_test_gesture_cancel_ladder()
	_test_gesture_rejection()

	# _checks is read BEFORE this call lands, so it holds the count of every
	# check above — compare it directly.
	_check("check count matches EXPECTED_CHECKS (a runtime error would abort a "
		+ "test function early and still print PASS)",
		_checks == EXPECTED_CHECKS,
		"ran %d, expected %d — update EXPECTED_CHECKS when adding checks"
			% [_checks, EXPECTED_CHECKS])

	if _fails == 0:
		print("TOOLBAR SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("TOOLBAR SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

func _test_registry_integrity() -> void:
	var seen: Dictionary = {}
	var st = StateScript.new()
	for t: Dictionary in StateScript.TOOLS:
		var id := String(t.get("id", ""))
		_check("tool has an id", not id.is_empty())
		_check("tool id unique: %s" % id, not seen.has(id))
		seen[id] = true
		var section := String(t.get("section", ""))
		_check("%s section is terrain|veg|camps|placement|water" % id,
			section == "terrain" or section == "veg" or section == "camps"
			or section == "placement" or section == "water")
		_check("%s has a label" % id, not String(t.get("label", "")).is_empty())
		_check("%s has a tooltip" % id, not String(t.get("tooltip", "")).is_empty())
		var shapes: Array = t.get("shapes", [])
		for sh: Variant in shapes:
			_check("%s shape %s is known" % [id, sh],
				["brush", "circle", "rect", "lasso", "polygon", "path"].has(String(sh)))
		# The default shape is shapes[0] — an empty list means a click gesture.
		_check("%s default shape resolves" % id,
			st.shape_for(id) == (String(shapes[0]) if not shapes.is_empty() else ""))
		for p: Variant in (t.get("params", []) as Array):
			var pd := p as Dictionary
			var key := String(pd.get("key", ""))
			var lo := float(pd.get("min", 0.0))
			var hi := float(pd.get("max", 0.0))
			var dv := float(pd.get("default", 0.0))
			_check("%s.%s has a label" % [id, key],
				not String(pd.get("label", "")).is_empty())
			_check("%s.%s min < max" % [id, key], lo < hi)
			_check("%s.%s default in range" % [id, key], dv >= lo and dv <= hi)
			_check("%s.%s step > 0" % [id, key], float(pd.get("step", 0.0)) > 0.0)
	_check("every section is populated",
		not st.tools_in_section("terrain").is_empty()
		and not st.tools_in_section("veg").is_empty()
		and not st.tools_in_section("camps").is_empty()
		and not st.tools_in_section("placement").is_empty()
		and not st.tools_in_section("water").is_empty())
	_check("unknown tool id is refused", not st.set_active_tool("nope"))
	_check("tool_def of an unknown id is empty", st.tool_def("nope").is_empty())


# ---------------------------------------------------------------------------
# Per-tool parameters — the regression the old docks shipped with
# ---------------------------------------------------------------------------

func _test_param_isolation() -> void:
	var st = StateScript.new()
	st.set_active_tool("raise")
	st.set_param("radius_m", 33.0)
	st.set_active_tool("smooth")
	_check("editing raise does not move smooth",
		absf(st.get_param("radius_m") - 16.0) < 0.01,
		"smooth radius read %f" % st.get_param("radius_m"))
	st.set_param("radius_m", 5.0)
	st.set_active_tool("raise")
	_check("raise keeps its own value across a switch (A->B->A)",
		absf(st.get_param("radius_m") - 33.0) < 0.01)
	st.set_active_tool("veg_paint")
	st.set_param("radius_m", 9.0)
	st.set_active_tool("raise")
	_check("veg radius does not leak into a terrain brush",
		absf(st.get_param("radius_m") - 33.0) < 0.01)
	st.set_active_tool("veg_clear")
	_check("veg_clear keeps its own default",
		absf(st.get_param("radius_m") - 6.0) < 0.01)

	# Clamping + unknown keys.
	st.set_active_tool("raise")
	st.set_param("hardness", 9.0)
	_check("value clamps to max", absf(st.get_param("hardness") - 1.0) < 1e-4)
	st.set_param("hardness", -5.0)
	_check("value clamps to min", absf(st.get_param("hardness")) < 1e-4)
	st.set_param("bogus_key", 1.0)
	_check("unknown param key is ignored",
		absf(st.get_param("bogus_key", -1.0) + 1.0) < 1e-6)
	st.set_tool_param("nope", "radius_m", 1.0)
	_check("set_tool_param on an unknown tool is a no-op", true)

	# params_for hands out a COPY — callers must not mutate the store.
	var snapshot: Dictionary = st.params_for("raise")
	snapshot["radius_m"] = 999.0
	_check("params_for returns a copy",
		absf(st.get_param("radius_m") - 33.0) < 0.01)


func _test_shape_memory() -> void:
	var st = StateScript.new()
	_check("level defaults to brush", st.shape_for("level") == "brush")
	_check("pond defaults to lasso", st.shape_for("pond") == "lasso")
	_check("set_shape accepts an allowed shape", st.set_shape("level", "rect"))
	_check("shape is remembered per tool", st.shape_for("level") == "rect")
	_check("pond shape untouched by the level edit", st.shape_for("pond") == "lasso")
	_check("set_shape refuses a shape the tool does not offer",
		not st.set_shape("raise", "lasso"))
	_check("refused shape left the value alone", st.shape_for("raise") == "brush")
	_check("set_shape refuses an unknown tool", not st.set_shape("nope", "rect"))


func _test_option_specs() -> void:
	var st = StateScript.new()
	st.set_active_tool("raise")
	st.set_param("radius_m", 21.0)
	var rows: Array = st.option_specs()
	_check("option_specs returns one row per param",
		rows.size() == (st.tool_def("raise")["params"] as Array).size())
	var found := false
	for r: Dictionary in rows:
		for k: String in ["key", "label", "min", "max", "step", "value"]:
			_check("option row carries %s" % k, r.has(k))
		if String(r["key"]) == "radius_m":
			found = true
			_check("option row carries the LIVE value, not the default",
				absf(float(r["value"]) - 21.0) < 0.01)
	_check("option_specs includes radius_m", found)
	_check("option_specs of an unknown tool is empty",
		st.option_specs("nope").is_empty())
	_check("option_specs of a param-less tool is empty",
		st.option_specs("measure").is_empty())


# ---------------------------------------------------------------------------
# Vegetation identity
# ---------------------------------------------------------------------------

## The load-bearing one: VEG_FAMILIES stores LITERAL ints (so the model loads
## with a stale global class cache). If VegetationPaint.Preset is ever
## reordered, every scatter would quietly paint the wrong family.
func _test_veg_families_match_preset_enum() -> void:
	var expect := {
		"pine": VegetationPaint.Preset.PINE,
		"deciduous": VegetationPaint.Preset.DECIDUOUS,
		"shrub": VegetationPaint.Preset.SHRUB,
		"mix": VegetationPaint.Preset.MIX,
		"grass_lawn": VegetationPaint.Preset.GRASS_LAWN,
		"grass_field": VegetationPaint.Preset.GRASS_FIELD,
	}
	_check("family count matches the Preset enum",
		StateScript.VEG_FAMILIES.size() == expect.size())
	for f: Dictionary in StateScript.VEG_FAMILIES:
		var fid := String(f["id"])
		_check("family %s is a real Preset" % fid, expect.has(fid))
		if expect.has(fid):
			_check("family %s preset int still matches the enum" % fid,
				int(f["preset"]) == int(expect[fid]),
				"stored %d, enum %d" % [int(f["preset"]), int(expect[fid])])


## CAMP_STYLES is a LITERAL copy of CampStyles' ids (same stale-class-cache
## reason as VEG_FAMILIES). Rename a style there and the toolbar would paint a
## style the layer silently normalises back to "mixed".
func _test_camp_styles() -> void:
	var ids: Array = []
	for s: Dictionary in StateScript.CAMP_STYLES:
		ids.append(String(s["id"]))
	var real: Array = CampStyles.STYLE_ORDER.duplicate()
	real.append(CampStyles.VARIED)
	_check("CAMP_STYLES matches CampStyles.STYLE_ORDER + varied", ids == real, str(ids))
	var st = StateScript.new()
	_check("default camp style is valid", CampStyles.is_valid(st.camp_style))
	_check("unknown camp style is refused", not st.set_camp_style("nope")
		and st.camp_style == "mixed")
	_check("varied is accepted", st.set_camp_style("varied"))
	_check("varied paints as mixed", st.camp_style_for_tool("camp_paint") == "mixed")
	_check("varied stays varied for Plots", st.camp_style_for_tool("camp_subdivide") == "varied")
	st.set_camp_style("rv_park")
	var cfg := ConfigFile.new()
	st.to_config(cfg)
	var back = StateScript.new()
	back.from_config(cfg)
	_check("camp style survives a config round-trip", back.camp_style == "rv_park")
	var bad := ConfigFile.new()
	bad.set_value("toolbar", "camp_style", "gone_in_this_build")
	var kept = StateScript.new()
	kept.from_config(bad)
	_check("a stale camp style in the config is ignored", kept.camp_style == "mixed")
	# Per-tool isolation holds across the camp tools too.
	st.set_tool_param("camp_paint", "density", 0.3)
	_check("camp tools keep separate params",
		is_equal_approx(float(st.params_for("camp_paint")["density"]), 0.3)
		and is_equal_approx(float(st.params_for("camp_subdivide")["density"]), 0.8))


## The PLACEMENT section's shared identity (allowed style mix, features,
## surface, equalise mode) and the LITERAL vocabularies it mirrors.
func _test_placement_state() -> void:
	_check("PLACEMENT_SURFACES mirrors FestivalPlacementLayer.SURFACES",
		Array(StateScript.PLACEMENT_SURFACES) == FestivalPlacementLayer.SURFACES)
	_check("PLACEMENT_FEATURES mirrors FestivalPlacementLayer.FEATURES",
		Array(StateScript.PLACEMENT_FEATURES) == FestivalPlacementLayer.FEATURES)
	var st = StateScript.new()
	_check("default style mix is one valid style", st.placement_styles == ["mixed"])
	_check("the last style cannot be toggled off", not st.toggle_placement_style("mixed")
		and st.placement_styles == ["mixed"])
	_check("a second style toggles on", st.toggle_placement_style("rv_park")
		and st.placement_styles == ["mixed", "rv_park"])
	_check("varied is not a placement style", not st.toggle_placement_style("varied"))
	_check("feature toggles on and off", st.toggle_placement_feature("power")
		and st.placement_features == ["power"] and st.toggle_placement_feature("power")
		and st.placement_features.is_empty())
	_check("unknown feature refused", not st.toggle_placement_feature("wifi"))
	_check("surface + equalise validated", st.set_placement_surface("playa")
		and not st.set_placement_surface("lava") and st.set_placement_equalise("raw")
		and not st.set_placement_equalise("fair"))
	# The Zone tool's rows + chips become ONE spec; target_n 0 means "by area".
	st.set_tool_param("fest_zone", "target_n", 0.0)
	var spec_a: Dictionary = st.placement_zone_spec()
	st.set_tool_param("fest_zone", "target_n", 6.0)
	var spec_n: Dictionary = st.placement_zone_spec()
	_check("zone spec: target_n 0 → area mode, else count mode",
		str(spec_a["mode"]) == "area" and str(spec_n["mode"]) == "count" and int(spec_n["target_n"]) == 6)
	_check("zone spec carries the chip state", spec_n["styles"] == ["mixed", "rv_park"]
		and str(spec_n["equalise"]) == "raw")
	_check("zone spec normalizes through the layer",
		int(FestivalPlacementLayer.normalize_spec(spec_n)["target_n"]) == 6)
	# Persistence round-trip of the placement identity.
	st.toggle_placement_feature("water")
	st.placement_subdivide_now = false
	var cfg := ConfigFile.new()
	st.to_config(cfg)
	var back = StateScript.new()
	back.from_config(cfg)
	_check("placement identity survives a config round-trip",
		back.placement_styles == ["mixed", "rv_park"] and back.placement_features == ["water"]
		and back.placement_surface == "playa" and back.placement_equalise == "raw"
		and back.placement_subdivide_now == false)
	var bad := ConfigFile.new()
	bad.set_value("toolbar", "placement_styles", ["gone", "varied"])
	bad.set_value("toolbar", "placement_features", ["wifi"])
	var kept = StateScript.new()
	kept.from_config(bad)
	_check("stale placement values in the config are ignored",
		kept.placement_styles == ["mixed"] and kept.placement_features.is_empty())


## The open-path gesture (festival roads): points accumulate, nothing closes.
func _test_gesture_path() -> void:
	var g = GestureScript.new()
	g.set_mode("path")
	_check("path is a region mode (Esc peels it)", g.is_region_mode())
	for pt: Vector2 in [Vector2(0, 0), Vector2(50, 0), Vector2(50, 40), Vector2(0.2, 0.2)]:
		_check("path accepts a bend", g.begin(pt, Vector2.ZERO, 3.0) == GestureScript.POLY_POINT)
	_check("path never closes on its first vertex", g.poly_points().size() == 4)
	_check("path reports pending work", g.has_pending() and not g.is_dragging())
	_check("finish returns the bends", g.finish_polygon().size() == 4 and g.poly_points().is_empty())
	_check("a one-point path is refused",
		not GestureScript.path_rejection_reason(PackedVector2Array([Vector2.ZERO])).is_empty())
	_check("a 3 km path is refused", not GestureScript.path_rejection_reason(
		PackedVector2Array([Vector2.ZERO, Vector2(3000, 0)])).is_empty())
	_check("a sane path is accepted", GestureScript.path_rejection_reason(
		PackedVector2Array([Vector2.ZERO, Vector2(300, 0), Vector2(300, 200)])).is_empty())
	var g2 = GestureScript.new()
	g2.set_mode("path")
	g2.begin(Vector2.ZERO, Vector2.ZERO)
	_check("Esc cancels a pending path", g2.cancel() and not g2.has_pending())


func _test_veg_identity() -> void:
	var st = StateScript.new()
	st.set_veg_family("pine")
	_check("family sets the preset index",
		st.veg_preset_index() == VegetationPaint.Preset.PINE)
	st.set_veg_species("spruce")
	# Re-selecting the SAME family must keep the subspecies: membership belongs
	# to the species catalog, and a name-prefix guess wrongly cleared spruce.
	st.set_veg_family("pine")
	_check("re-selecting a family keeps its subspecies", st.veg_species == "spruce")
	st.set_veg_family("deciduous")
	_check("changing family resets the subspecies to the family id",
		st.veg_species == "deciduous")
	st.set_veg_family("mix")
	_check("MIX reports itself as mix", st.is_mix_family())
	_check("MIX carries no single species", st.veg_species == "")
	_check("MIX maps to the MIX preset",
		st.veg_preset_index() == VegetationPaint.Preset.MIX)
	_check("leaving MIX restores a family species",
		st.set_veg_family("shrub") and st.veg_species == "shrub")
	_check("unknown family is refused", not st.set_veg_family("bogus"))
	_check("refused family left the value alone", st.veg_family == "shrub")

	# size_var is authored in PERCENT and consumed as a 0..0.5 fraction.
	st.set_active_tool("veg_paint")
	st.set_param("size_var", 40.0)
	_check("size_var percent -> fraction",
		absf(st.size_var_fraction() - 0.4) < 1e-4)
	st.set_param("size_var", 999.0)
	_check("size_var fraction stays within 0..0.5",
		st.size_var_fraction() <= 0.5 + 1e-6)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _test_config_round_trip() -> void:
	var st = StateScript.new()
	st.set_active_tool("veg_paint")
	st.set_param("radius_m", 7.5)
	st.set_shape("level", "polygon")
	st.set_veg_family("pine")
	st.set_veg_species("spruce")
	st.hero_preset = "oak_2"
	st.set_param("scale", 1.8)
	st.veg_mix_id = "pnw_lowland"
	st.set_active_tool("lower")
	st.set_param("strength", 3.25)

	var cfg := ConfigFile.new()
	st.to_config(cfg)
	var st2 = StateScript.new()
	st2.from_config(cfg)

	_check("active tool survives", st2.active_tool == "lower")
	_check("terrain param survives",
		absf(st2.params_for("lower")["strength"] - 3.25) < 1e-4)
	_check("veg param survives",
		absf(st2.params_for("veg_paint")["radius_m"] - 7.5) < 1e-4)
	_check("per-tool shape survives", st2.shape_for("level") == "polygon")
	_check("veg family survives", st2.veg_family == "pine")
	_check("veg species survives", st2.veg_species == "spruce")
	_check("hero preset survives", st2.hero_preset == "oak_2")
	_check("plant scale survives",
		absf(st2.params_for("veg_paint")["scale"] - 1.8) < 1e-4)
	_check("mix choice survives", st2.veg_mix_id == "pnw_lowland")
	_check("plant scale defaults to 1",
		absf(StateScript.new().get_tool_param_value("veg_paint", "scale") - 1.0) < 1e-4)
	_check("untouched tools keep their defaults",
		absf(st2.params_for("smooth")["radius_m"] - 16.0) < 1e-4)


## A config from an older/newer build, or a hand-edited one, must never break
## the model — unknown entries are ignored and missing ones keep defaults.
func _test_config_robustness() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("toolbar", "active_tool", "a_tool_that_does_not_exist")
	cfg.set_value("toolbar", "veg_family", "not_a_family")
	cfg.set_value("tool_raise", "radius_m", 4242.0)     # far out of range
	cfg.set_value("tool_raise", "unknown_param", 1.0)
	cfg.set_value("tool_ghost_tool", "radius_m", 5.0)   # tool no longer exists
	cfg.set_value("tool_level", "shape", "not_a_shape")

	var st = StateScript.new()
	st.from_config(cfg)
	_check("unknown active_tool is ignored", st.active_tool == "raise")
	_check("unknown veg family is ignored", st.veg_family == "shrub")
	_check("out-of-range stored value is clamped",
		absf(st.params_for("raise")["radius_m"] - 100.0) < 1e-4,
		"read %f" % float(st.params_for("raise")["radius_m"]))
	_check("unknown stored param key is ignored",
		not st.params_for("raise").has("unknown_param"))
	_check("section for a removed tool is ignored", st.tool_def("ghost_tool").is_empty())
	_check("invalid stored shape is ignored", st.shape_for("level") == "brush")

	var missing = StateScript.new()
	_check("loading a nonexistent file reports false",
		not missing.load_from("user://toolbar_selftest_does_not_exist.cfg"))
	_check("failed load leaves defaults intact",
		absf(missing.params_for("raise")["radius_m"] - 12.0) < 1e-4)


## Exercise the real save/load path against a TEMP file, so a player's actual
## user://toolbar_prefs.cfg is never touched by the suite.
func _test_file_round_trip() -> void:
	var path := "user://toolbar_selftest_tmp.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var st = StateScript.new()
	st.set_active_tool("veg_clear")
	st.set_param("radius_m", 11.5)
	st.set_veg_family("deciduous")
	_check("save_to writes the file", st.save_to(path) == OK)
	_check("the file exists after save", FileAccess.file_exists(path))

	var st2 = StateScript.new()
	_check("load_from reports success", st2.load_from(path))
	_check("file round-trip preserves the active tool", st2.active_tool == "veg_clear")
	_check("file round-trip preserves a param",
		absf(st2.params_for("veg_clear")["radius_m"] - 11.5) < 1e-4)
	_check("file round-trip preserves the veg family", st2.veg_family == "deciduous")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check("temp prefs file cleaned up", not FileAccess.file_exists(path))


# ---------------------------------------------------------------------------
# Shape gestures
# ---------------------------------------------------------------------------

func _test_gesture_shapes() -> void:
	var g = GestureScript.new()
	g.set_mode("rect")
	_check("rect press starts a drag",
		g.begin(Vector2.ZERO, Vector2(100, 100)) == GestureScript.DRAG_STARTED)
	_check("dragging reports true", g.is_dragging())
	g.update_drag(Vector2(50, 40))
	_check("rect builds a preview outline", g.preview_world().size() >= 3)
	var poly: PackedVector2Array = g.release()
	_check("release yields the outline", poly.size() >= 3)
	_check("release ends the drag", not g.is_dragging())
	_check("released rect is usable", GestureScript.rejection_reason(poly) == "")

	# A circle cannot be dragged past the radius cap.
	var g2 = GestureScript.new()
	g2.set_mode("circle")
	g2.begin(Vector2.ZERO, Vector2.ZERO)
	g2.update_drag(Vector2(9999.0, 0.0))
	var maxr := 0.0
	for p: Vector2 in g2.preview_world():
		maxr = maxf(maxr, p.length())
	_check("circle radius is capped at MAX_RADIUS_M",
		maxr <= GestureScript.MAX_RADIUS_M + 0.01, "got %f" % maxr)

	# Lasso samples only past the pixel threshold.
	var g3 = GestureScript.new()
	g3.set_mode("lasso")
	g3.begin(Vector2.ZERO, Vector2(10, 10))
	_check("lasso ignores a sub-threshold move", not g3.motion(Vector2(1, 0), Vector2(12, 10)))
	_check("lasso takes a far-enough sample", g3.motion(Vector2(5, 0), Vector2(40, 10)))
	_check("lasso keeps the screen trail for drawing", g3.lasso_screen().size() == 2)

	# Switching mode drops transient state.
	var g4 = GestureScript.new()
	g4.set_mode("rect")
	g4.begin(Vector2.ZERO, Vector2.ZERO)
	g4.set_mode("lasso")
	_check("mode switch clears a live drag", not g4.is_dragging())
	_check("mode switch clears pending state", not g4.has_pending())
	_check("brush mode is not a region mode",
		not GestureScript.new().is_region_mode())


func _test_gesture_polygon() -> void:
	var g = GestureScript.new()
	g.set_mode("polygon")
	for pt: Vector2 in [Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]:
		_check("polygon accepts a corner",
			g.begin(pt, Vector2.ZERO) == GestureScript.POLY_POINT)
	_check("polygon is not a drag", not g.is_dragging())
	_check("polygon reports pending work", g.has_pending())
	_check("clicking near the first corner closes the ring",
		g.begin(Vector2(0.5, 0.5), Vector2.ZERO, 3.0) == GestureScript.POLY_CLOSED)
	_check("finish_polygon returns every corner", g.finish_polygon().size() == 3)
	_check("finish_polygon clears the state", g.poly_points().size() == 0)


func _test_gesture_cancel_ladder() -> void:
	var g = GestureScript.new()
	g.set_mode("polygon")
	g.begin(Vector2.ZERO, Vector2.ZERO)
	_check("cancel peels the pending polygon", g.cancel())
	_check("cancel reports nothing left to peel", not g.cancel())

	var g2 = GestureScript.new()
	g2.set_mode("lasso")
	g2.begin(Vector2.ZERO, Vector2.ZERO)
	_check("cancel peels a live drag", g2.cancel())
	_check("cancelled drag is over", not g2.is_dragging())


## Rejections return the REASON, which is what lets the toolbar explain itself
## instead of silently swallowing a drawn shape.
func _test_gesture_rejection() -> void:
	_check("a 2-point outline is refused",
		not GestureScript.rejection_reason(
			PackedVector2Array([Vector2.ZERO, Vector2(1, 1)])).is_empty())
	var huge := PackedVector2Array([Vector2(0, 0), Vector2(2000, 0),
		Vector2(2000, 2000), Vector2(0, 2000)])
	_check("an oversized outline is refused",
		not GestureScript.rejection_reason(huge).is_empty())
	var ok := VegetationPaint.circle_polygon(Vector2.ZERO, 20.0)
	_check("a sane outline is accepted",
		GestureScript.rejection_reason(ok).is_empty())

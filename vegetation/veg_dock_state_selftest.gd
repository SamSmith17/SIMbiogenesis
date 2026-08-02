extends SceneTree

## Headless self-test for the vegetation paint dock's STATE (veg overhaul
## Phase 8) — the chip row, the tool/shape/species state machine, and the
## per-tree Select primitives on VegetationLayer.
##
## The dock has no class_name (like most of scenes/ui/), so ui_compile_selftest
## only proves it parses. This instantiates it for real and drives the same
## methods the buttons call, which is what catches "the chip row says pine
## while the brush paints shrub".
##
## Run with:
##   godot --headless --path . --script vegetation/veg_dock_state_selftest.gd

## Loaded in _initialize (NOT a const preload) for the same reason
## ui_compile_selftest does it: a preload resolves when THIS script compiles,
## which is before autoloads register, and the dock references CursorController
## at parse time. A preload therefore fails to compile, every dock.call()
## silently no-ops, and the suite still reports PASS — the exact trap this file
## exists to close.
const DOCK_PATH := "res://scenes/ui/vegetation_edit_ui.gd"

var DockScript: GDScript = null
var Tool: Dictionary = {}
var ShapeMode: Dictionary = {}
var FAMILY_CHIP_COLORS: Dictionary = {}

var _failures := 0
var _checks := 0


## The suite runs on the first PROCESS frame, not in _initialize: the SceneTree
## root is not itself inside the tree yet during _initialize, so an added child
## never gets _ready() and none of the dock's Controls would exist. Waiting one
## frame gives a real tree, which is the difference between testing the dock and
## testing a bag of default values.
func _initialize() -> void:
	pass


func _process(_delta: float) -> bool:
	_run()
	return true


func _run() -> void:
	DockScript = load(DOCK_PATH) as GDScript
	if DockScript == null:
		print("VEG DOCK STATE SELFTEST FAIL  (dock script failed to compile)")
		quit(1)
		return
	var consts := DockScript.get_script_constant_map()
	Tool = consts.get("Tool", {})
	ShapeMode = consts.get("ShapeMode", {})
	FAMILY_CHIP_COLORS = consts.get("FAMILY_CHIP_COLORS", {})
	_check("dock enums resolved", Tool.has("PAINT") and ShapeMode.has("BRUSH"))
	_check("chip palette resolved", FAMILY_CHIP_COLORS.has("pine"))
	_test_chip_model()
	_test_species_state()
	_test_tool_state()
	_test_nearest_plant()
	_test_plant_edit_ops()
	if _failures == 0:
		print("VEG DOCK STATE SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG DOCK STATE SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


## A dock instance, built and in the tree, so its Controls exist. Callers free it.
func _make_dock() -> Control:
	var dock := Control.new()
	dock.set_script(DockScript)
	get_root().add_child(dock)
	return dock


func _chip_texts(dock: Control) -> Array:
	var out: Array = []
	for spec in dock.call("chip_specs"):
		out.append(str((spec as Dictionary).get("text", "")))
	return out


func _has_chip(dock: Control, fragment: String) -> bool:
	for t in _chip_texts(dock):
		if str(t).findn(fragment) >= 0:
			return true
	return false


## --- Chip row ---------------------------------------------------------------

func _test_chip_model() -> void:
	var dock := _make_dock()
	var chips: Array = dock.call("chip_specs")
	_check("chip row is never empty", chips.size() >= 3, "got %d" % chips.size())
	for spec in chips:
		var d: Dictionary = spec
		_check("chip carries text", not str(d.get("text", "")).is_empty())
		_check("chip carries a colour", d.get("color") is Color)

	# The tool is part of the first chip, so the row always answers "what will
	# clicking do?" — the question the old status label kept losing.
	_check("first chip names the tool", str((chips[0] as Dictionary).get("text", "")).begins_with("Paint"))
	dock.call("_set_tool", Tool["CLEAR"])
	_check("tool chip follows the tool", _has_chip(dock, "Clear"))
	dock.call("_set_tool", Tool["PAINT"])

	# Density and brush radius are live numbers, not just slider positions...
	dock.call("set_paint_density", 2.5)
	_check("density chip shows the value", _has_chip(dock, "2.50"))
	# ...and a value pushed from the Tune-look modal must move the WIDGET too,
	# or the dock shows one density and the slider snaps back to another on the
	# next drag.
	var dens_row: Dictionary = dock.get("_density_row")
	var dens_slider: HSlider = dens_row.get("slider") if not dens_row.is_empty() else null
	_check("density slider follows the setter",
		dens_slider != null and is_equal_approx(dens_slider.value, 2.5),
		str(dens_slider.value) if dens_slider != null else "no slider")
	dock.call("set_paint_density", 1.0)
	_check("density slider follows back",
		dens_slider != null and is_equal_approx(dens_slider.value, 1.0))

	# Brush-override is the state that used to be completely invisible.
	_check("no custom-look chip by default", not _has_chip(dock, "custom look"))
	dock.call("set_brush_style", {"deciduous_canopy_w": 3.0})
	_check("custom-look chip appears with a brush style", _has_chip(dock, "custom look"))
	_check("has_brush_style agrees", bool(dock.call("has_brush_style")))
	dock.call("set_brush_style", {})
	_check("custom-look chip clears with the brush style", not _has_chip(dock, "custom look"))
	_check("has_brush_style agrees when cleared", not bool(dock.call("has_brush_style")))

	# Size variance only earns a chip when it is actually doing something.
	dock.call("set_size_var", 0.0)
	_check("no size chip at zero variance", not _has_chip(dock, "size"))
	dock.call("set_size_var", 0.4)
	_check("size chip appears with variance", _has_chip(dock, "40% size"))

	dock.queue_free()


## --- Species / preset coupling ---------------------------------------------

func _test_species_state() -> void:
	var dock := _make_dock()
	# Setting a species must move the PRESET too, or the dock's type buttons
	# disagree with what the brush paints.
	dock.call("set_paint_species", "spruce")
	_check("species applied", str(dock.call("get_paint_species")) == "spruce")
	_check("spruce chip reads spruce", _has_chip(dock, "Spruce"))
	_check("conifer species picks the pine swatch",
		DockScript.call("species_chip_color", "spruce", 0) == FAMILY_CHIP_COLORS["pine"])
	dock.call("set_paint_species", "birch")
	_check("broadleaf species picks the deciduous swatch",
		DockScript.call("species_chip_color", "birch", 0) == FAMILY_CHIP_COLORS["deciduous"])
	# An unpaintable / unknown id is refused rather than silently accepted.
	var before := str(dock.call("get_paint_species"))
	dock.call("set_paint_species", "not_a_species")
	_check("unknown species refused", str(dock.call("get_paint_species")) == before)
	dock.call("set_paint_species", "")
	_check("empty species refused", str(dock.call("get_paint_species")) == before)
	dock.queue_free()


## --- Tool / shape state -----------------------------------------------------

func _test_tool_state() -> void:
	var dock := _make_dock()
	for t in [Tool["PAINT"], Tool["PLACE"],
			Tool["CLEAR"], Tool["SELECT"]]:
		dock.call("_set_tool", t)
		_check("tool %d applies" % t, int(dock.get("_tool")) == int(t))
		_check("chips survive tool %d" % t, (dock.call("chip_specs") as Array).size() >= 3)
	# The hero row is only meaningful for Place.
	dock.call("_set_tool", Tool["PLACE"])
	var hero_row: Control = dock.get("_hero_section")
	_check("hero row shows for Place", hero_row != null and hero_row.visible)
	dock.call("_set_tool", Tool["PAINT"])
	_check("hero row hides for Paint", hero_row != null and not hero_row.visible)

	for m in [ShapeMode["BRUSH"], ShapeMode["CIRCLE"],
			ShapeMode["RECT"], ShapeMode["LASSO"],
			ShapeMode["POLYGON"]]:
		dock.call("_on_shape_mode_pressed", m)
		_check("shape %d applies" % m, int(dock.get("_shape_mode")) == int(m))
	# Non-brush shapes name themselves in the chip row; brush shows its radius.
	dock.call("_on_shape_mode_pressed", ShapeMode["LASSO"])
	_check("shape chip names the shape", _has_chip(dock, "lasso"))
	dock.call("_on_shape_mode_pressed", ShapeMode["BRUSH"])
	_check("brush shape chip shows a radius", _has_chip(dock, "r "))

	# Top-down with no drone in the scene must refuse cleanly, not half-enter.
	dock.call("_set_topdown", true)
	_check("top-down without a drone stays off", not bool(dock.get("_topdown")))
	dock.queue_free()


## --- Per-tree Select primitives (VegetationLayer) ---------------------------

func _make_layer() -> VegetationLayer:
	var layer := VegetationLayer.new()
	layer.add_bulk("pine", 0.0, 0.0, 0.0, 1.0)
	layer.add_bulk("pine", 30.0, 0.0, 0.0, 1.5)
	layer.add_bulk("shrub", 2.0, 2.0, 0.0, 0.8)
	return layer


func _test_nearest_plant() -> void:
	var layer := _make_layer()
	var hit := layer.nearest_plant(Vector2(0.2, 0.1), 6.0)
	_check("picks the closest plant", str(hit.get("species", "")) == "pine"
		and int(hit.get("index", -1)) == 0, str(hit))
	_check("pick reports its distance", float(hit.get("dist_m", -1.0)) < 0.5)
	var shrub := layer.nearest_plant(Vector2(2.1, 2.1), 6.0)
	_check("picks across species", str(shrub.get("species", "")) == "shrub")
	# Radius is a real cutoff, not a suggestion — otherwise a click on bare
	# ground silently selects something on the far side of the map.
	_check("nothing outside the radius", layer.nearest_plant(Vector2(200.0, 200.0), 6.0).is_empty())
	_check("radius edge respected", layer.nearest_plant(Vector2(12.0, 0.0), 6.0).is_empty())
	_check("wider radius reaches it", not layer.nearest_plant(Vector2(12.0, 0.0), 20.0).is_empty())
	# Heroes are pickable too.
	layer.add_hero("pine_1", 5.0, 5.0, 0.0, 1.0, 0.0)
	var hero := layer.nearest_plant(Vector2(5.0, 5.0), 3.0)
	_check("hero is pickable", str(hero.get("kind", "")) == "hero")
	_check("empty layer picks nothing",
		VegetationLayer.new().nearest_plant(Vector2.ZERO, 10.0).is_empty())


func _test_plant_edit_ops() -> void:
	var layer := _make_layer()
	var before: int = (layer.bulk.get("pine", []) as Array).size()
	var desc := layer.nearest_plant(Vector2.ZERO, 6.0)
	_check("delete removes exactly one", layer.remove_plant(desc)
		and (layer.bulk.get("pine", []) as Array).size() == before - 1)
	_check("the OTHER pine survived", (layer.bulk.get("pine", []) as Array).size() == 1)
	_check("deleting nothing is a no-op", not layer.remove_plant({}))
	# A stale index must be refused rather than deleting whatever moved into it.
	_check("out-of-range index refused",
		not layer.remove_plant({"kind": "bulk", "species": "pine", "index": 99}))

	var s_desc := layer.nearest_plant(Vector2(30.0, 0.0), 6.0)
	var s_before := float(s_desc.get("scale", 1.0))
	_check("resize applies", layer.scale_plant(s_desc, 2.0))
	var after := layer.nearest_plant(Vector2(30.0, 0.0), 6.0)
	_check("resize multiplied the scale",
		is_equal_approx(float(after.get("scale", 0.0)), s_before * 2.0),
		"%.3f -> %.3f" % [s_before, float(after.get("scale", 0.0))])
	# Clamped, so repeated growth can't produce a skyscraper.
	for i in 12:
		layer.scale_plant(layer.nearest_plant(Vector2(30.0, 0.0), 6.0), 2.0)
	var huge := layer.nearest_plant(Vector2(30.0, 0.0), 6.0)
	_check("scale is clamped", float(huge.get("scale", 0.0)) <= 4.0 + 1e-4,
		str(huge.get("scale", 0.0)))
	_check("zero factor refused", not layer.scale_plant(huge, 0.0))

	# Hero delete goes through the same descriptor path.
	layer.add_hero("pine_1", 50.0, 50.0, 0.0, 1.0, 0.0)
	var h := layer.nearest_plant(Vector2(50.0, 50.0), 3.0)
	_check("hero delete works", layer.remove_plant(h) and layer.hero.is_empty())

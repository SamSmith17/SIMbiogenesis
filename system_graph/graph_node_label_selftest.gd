extends SceneTree

## Offline checks for GraphNodeLabel sizing + NODE_SIZES defaults (Phase 4).

const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_body_font_clamp()
	fails += _test_title_band_height()
	fails += _test_ellipsis()
	fails += _test_node_size_defaults()
	fails += _test_resource_edge_vis()
	if fails == 0:
		print("GRAPH NODE LABEL SELFTEST PASS  (5 checks)")
	else:
		print("GRAPH NODE LABEL SELFTEST FAIL  (%d failed)" % fails)
	quit()


func _test_body_font_clamp() -> int:
	var tiny := GraphNodeLabel.body_font_size(Rect2(0, 0, 40, 24), 2)
	var huge := GraphNodeLabel.body_font_size(Rect2(0, 0, 400, 280), 1, 11.0, 13.0)
	if tiny < GraphNodeLabel.BODY_FONT_MIN or tiny > GraphNodeLabel.BODY_FONT_MAX:
		push_error("tiny body font out of range: %d" % tiny)
		return 1
	if huge > GraphNodeLabel.BODY_FONT_MAX:
		push_error("huge body font should clamp at BODY_FONT_MAX, got %d" % huge)
		return 1
	return 0


func _test_title_band_height() -> int:
	var lo := GraphNodeLabel.title_band_height(60.0)
	var hi := GraphNodeLabel.title_band_height(400.0)
	if lo < GraphNodeLabel.TITLE_BAND_MIN_PX or lo > GraphNodeLabel.TITLE_BAND_MAX_PX:
		push_error("title band low zoom out of range: %f" % lo)
		return 1
	if hi < GraphNodeLabel.TITLE_BAND_MIN_PX or hi > GraphNodeLabel.TITLE_BAND_MAX_PX:
		push_error("title band high zoom out of range: %f" % hi)
		return 1
	return 0


func _test_ellipsis() -> int:
	var fnt := ThemeDB.fallback_font
	var long := "Greywater Holding Tank — Bombay Beach Site A"
	var short := GraphNodeLabel.ellipsis(fnt, long, 90.0, 11)
	if short == long:
		push_error("ellipsis should shorten long title")
		return 1
	if fnt.get_string_size(short, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x > 92.0:
		push_error("ellipsis result still too wide: %s" % short)
		return 1
	if GraphNodeLabel.ellipsis(fnt, "OK", 90.0, 11) != "OK":
		push_error("ellipsis should not alter short text")
		return 1
	return 0


func _test_node_size_defaults() -> int:
	if GraphCanvasScript.default_width("processor") < 170.0:
		push_error("processor default width too small")
		return 1
	if GraphCanvasScript.default_width("resource") < 128.0:
		push_error("resource default width too small")
		return 1
	if GraphCanvasScript.default_height("controller") < 150.0:
		push_error("controller default height too small")
		return 1
	return 0


func _test_resource_edge_vis() -> int:
	var idle: Dictionary = ResourceEdgeVis.stroke_for("water", 0.0, false)
	if float(idle.get("width", 0.0)) < ResourceEdgeVis.WIDTH_IDLE - 0.01:
		push_error("idle resource width too thin")
		return 1
	var live: Dictionary = ResourceEdgeVis.stroke_for("water", 60.0, true)
	if float(live.get("width", 0.0)) < ResourceEdgeVis.WIDTH_MIN_ACTIVE:
		push_error("active resource width below minimum")
		return 1
	if ResourceEdgeVis.glow_scale("water", 60.0, true) <= 0.0:
		push_error("expected positive glow scale for flowing water")
		return 1
	if ResourceEdgeVis.glow_scale("water", 0.0, false) != 0.0:
		push_error("idle glow scale should be zero")
		return 1
	return 0

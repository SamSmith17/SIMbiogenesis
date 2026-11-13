extends SceneTree

## GraphFlowStyle + GraphFlowRibbons selftest (offline). Pins the Sankey width
## rule (proportional inside a resource, sqrt / log monotone, trickle floor,
## screen-space vs zoom, per-wire overrides incl. the old sankey_scale
## migration), preset resolution and the sparse save form, the animation
## speed capped below strobing and independent of anything but the flow, the
## pattern moving the right way, the reference easing (fast up, slow down),
## exact display averaging, legend ticks, and the ribbon geometry (its width
## on screen, sample spacing, a sharp corner never spiking).
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite still prints PASS.
##   godot --headless --path . --script system_graph/graph_flow_style_selftest.gd

const EXPECTED_CHECKS := 61

var _checks := 0
var _fails := 0


func _init() -> void:
	_test_resolve()
	_test_widths()
	_test_overrides()
	_test_motion()
	_test_easing()
	_test_legend()
	_test_ribbon_geometry()
	_test_conduits()
	_test_looks()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("GRAPH FLOW STYLE SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


## The look presets and knobs: every preset resolves to itself and saves as
## its bare name, the look keys clamp, the old gradient bool migrates, the
## pattern's spacing and length do what they say, cached geometry draws the
## same ribbon, taper narrows the ends, and the heat ramp warms with flow.
func _test_looks() -> void:
	var all_ok := true
	for pr in GraphFlowStyle.PRESETS:
		var st := GraphFlowStyle.resolve({"preset": pr})
		if str(st["preset"]) != str(pr) or GraphFlowStyle.to_sparse(st).size() != 1:
			all_ok = false
	_ok(all_ok, "every preset resolves to itself and saves as its bare name")
	_ok(GraphFlowStyle.WIDTH_PRESETS.size() + GraphFlowStyle.LOOK_PRESETS.size() == GraphFlowStyle.PRESETS.size(),
		"the two preset rows hold every preset")
	var ink := GraphFlowStyle.resolve({"preset": GraphFlowStyle.PRESET_INK})
	_ok(float(ink["glow"]) == 0.0 and str(ink["colour"]) == GraphFlowStyle.COLOUR_KIND,
		"Ink is flat and in resource colours")
	var cl := GraphFlowStyle.resolve({"glow_w": 99.0, "sat": -3.0, "duty": 7.0, "lens_gap": 1.0})
	_ok(is_equal_approx(float(cl["glow_w"]), 5.0) and is_equal_approx(float(cl["sat"]), 0.0)
		and is_equal_approx(float(cl["duty"]), 1.0) and is_equal_approx(float(cl["lens_gap"]), 36.0),
		"look and lens keys clamp to their ranges")
	_ok(str(GraphFlowStyle.resolve({"gradient": false})["colour"]) == GraphFlowStyle.COLOUR_KIND,
		"an old 'gradient off' save reads as resource colour")
	_ok(str(GraphFlowStyle.resolve({"gradient": false, "colour": "heat"})["colour"]) == "heat",
		"a saved colour mode beats the old bool")
	var bad := GraphFlowStyle.resolve({"colour": "plaid", "accent": "nope"})
	_ok(str(bad["colour"]) == GraphFlowStyle.COLOUR_GRADIENT and str(bad["accent"]) == "8cd9ff",
		"an unknown colour mode or accent falls back")
	var lk := GraphFlowStyle.look(GraphFlowStyle.resolve({"colour": "mono", "accent": "#ff0000"}))
	_ok(lk["accent"] is Color and (lk["accent"] as Color).r > 0.99 and (lk["accent"] as Color).g < 0.01,
		"look() hands the accent over as a colour")
	# Pattern length: a longer duty lights more of each period.
	var lit := []
	for d in [0.2, 0.5, 0.9]:
		var sum := 0.0
		for k in 88:
			sum += GraphFlowStyle.pattern_ex(GraphFlowStyle.ANIM_STREAKS, float(k), 0.0, 0.0, false, false, 1.0, d)
		lit.append(sum / 88.0)
	_ok(lit[0] < lit[1] and lit[1] < lit[2], "a longer streak length lights more of the wire (%.2f %.2f %.2f)" % lit)
	var a := GraphFlowStyle.pattern_ex(GraphFlowStyle.ANIM_COMETS, 30.0, 0.0, 0.0, false, false, 1.0, 0.5)
	var b := GraphFlowStyle.pattern_ex(GraphFlowStyle.ANIM_COMETS, 60.0, 0.0, 0.0, false, false, 2.0, 0.5)
	_ok(is_equal_approx(a, b), "spacing ×2 draws the same pattern twice as far apart")
	_ok(is_equal_approx(GraphFlowStyle.pattern(GraphFlowStyle.ANIM_BEADS, 7.0, 0.3, 40.0, false),
		GraphFlowStyle.pattern_ex(GraphFlowStyle.ANIM_BEADS, 7.0, 0.3, 40.0, false, false, 1.0, 0.5)),
		"pattern() is pattern_ex at the natural spacing and length")
	# Cached geometry draws the same ribbon.
	var path := PackedVector2Array([Vector2(0, 0), Vector2(120, 40), Vector2(300, 10)])
	var o := {"width": 14.0, "color": Color.ORANGE, "active": true, "t": 0.4, "speed": 60.0,
		"look": GraphFlowStyle.look(GraphFlowStyle.resolve({"preset": "neon"}))}
	var r1 := GraphFlowRibbons.build(path, o)
	var o2 := o.duplicate()
	o2["geo"] = GraphFlowRibbons.geometry(path, GraphFlowRibbons.STEP_PX)
	var r2 := GraphFlowRibbons.build(path, o2)
	_ok(r1["pts"] == r2["pts"] and r1["cols"] == r2["cols"], "cached geometry draws the same ribbon")
	# Taper: the ends narrower than the middle.
	var line := PackedVector2Array([Vector2(0, 0), Vector2(400, 0)])
	var tl := GraphFlowStyle.look(GraphFlowStyle.resolve({"taper": 1.0, "glow": 0.0}))
	var rt := GraphFlowRibbons.build(line, {"width": 20.0, "color": Color.WHITE, "active": false, "look": tl})
	var end_w := 0.0
	var mid_w := 0.0
	for pt in (rt["pts"] as PackedVector2Array):
		if pt.x < 1.0:
			end_w = maxf(end_w, absf(pt.y))
		if absf(pt.x - 200.0) < 3.0:
			mid_w = maxf(mid_w, absf(pt.y))
	_ok(end_w < mid_w * 0.5 and is_equal_approx(mid_w, 10.0), "taper narrows the ends, not the middle")
	var h0 := GraphFlowRibbons.heat_color(0.1)
	var h1 := GraphFlowRibbons.heat_color(0.95)
	_ok(h1.get_luminance() > h0.get_luminance() + 0.3, "the heat ramp warms toward white with flow")
	_ok(GraphFlowRibbons.grade(Color(1, 0, 0), 0.0, 1.0).is_equal_approx(
		GraphFlowRibbons.grade(Color(1, 0, 0), 0.0, 1.0).lerp(Color(0.299, 0.299, 0.299), 1.0)),
		"saturation 0 is grey")


## The 3D runs follow the same rule: brighter and faster where more flows.
func _test_conduits() -> void:
	var st := GraphFlowStyle.resolve({"preset": "sankey"})
	var lo := ConduitManager.flow_glow_for(st, 5.0, 100.0)
	var hi := ConduitManager.flow_glow_for(st, 100.0, 100.0)
	_ok(hi.x > lo.x and hi.y > lo.y, "a 3D run carrying more glows brighter and scrolls faster")
	_ok(ConduitManager.flow_glow_for(st, 0.0, 100.0).x > 0.0, "an idle run keeps a quiet floor")
	_ok(str(ConduitManager.flow_measure({"carried_amps": 8.0})[0]) == "electricity",
		"a power run is measured in amps on the electricity scale")
	var m := ConduitManager.flow_measure({"flow_rate": 120.0, "kind": "water"})
	_ok(str(m[0]) == "water" and absf(float(m[1]) - 120.0) < 1e-9, "a water run in L/h on its own scale")


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)


func _test_resolve() -> void:
	var d := GraphFlowStyle.resolve({})
	_ok(str(d["preset"]) == GraphFlowStyle.PRESET_SANKEY, "default preset is Sankey")
	var b := GraphFlowStyle.resolve({"preset": "bold"})
	_ok(bool(b["screen_space"]) and float(b["thickness"]) > float(d["thickness"]), "Bold is thicker and screen-space")
	var c := GraphFlowStyle.resolve({"preset": "sankey", "thickness": 999.0, "scale": "nonsense"})
	_ok(float(c["thickness"]) == GraphFlowStyle.THICKNESS_MAX and str(c["scale"]) == "linear",
		"out-of-range values clamp, unknown scale falls back")
	_ok(GraphFlowStyle.to_sparse(GraphFlowStyle.resolve({"preset": "subtle"})) == {"preset": "subtle"},
		"a plain preset saves as just its name")
	var sp := GraphFlowStyle.to_sparse(GraphFlowStyle.resolve({"preset": "sankey", "glow": 0.2}))
	_ok(sp.size() == 2 and is_equal_approx(float(sp["glow"]), 0.2), "a changed knob is kept sparse")
	_ok(GraphFlowStyle.label_of({"preset": "sankey", "glow": 0.2}) == "Custom"
		and GraphFlowStyle.label_of({"preset": "bold"}) == "Bold", "label reads Custom once it differs")
	_ok(GraphFlowStyle.is_classic(GraphFlowStyle.resolve({"preset": "classic"}))
		and not GraphFlowStyle.is_classic(d), "classic detection")


func _test_widths() -> void:
	var st := GraphFlowStyle.resolve({"preset": "sankey", "min_px": 0.5})
	var full := GraphFlowStyle.width_px(st, 100.0, 100.0, true, 1.0)
	var half := GraphFlowStyle.width_px(st, 50.0, 100.0, true, 1.0)
	var tenth := GraphFlowStyle.width_px(st, 10.0, 100.0, true, 1.0)
	_ok(is_equal_approx(full, float(st["thickness"])), "the reference flow is the full thickness")
	_ok(is_equal_approx(half * 2.0, full), "linear: half the flow is half the width")
	_ok(is_equal_approx(tenth * 10.0, full), "linear: a tenth is a tenth")
	var floor_st := GraphFlowStyle.resolve({"preset": "sankey", "min_px": 3.0})
	_ok(GraphFlowStyle.width_px(floor_st, 0.001, 100.0, true, 1.0) >= 3.0, "a trickle never drops below min_px")
	_ok(GraphFlowStyle.width_px(st, 0.0, 100.0, false, 1.0) < half, "an idle wire is thin")
	var sq := GraphFlowStyle.resolve({"preset": "subtle", "min_px": 0.5})
	var a := GraphFlowStyle.width_px(sq, 10.0, 100.0, true, 1.0)
	var bq := GraphFlowStyle.width_px(sq, 40.0, 100.0, true, 1.0)
	_ok(bq > a and is_equal_approx(bq / a, 2.0), "sqrt: four times the flow, twice the width")
	var lg := GraphFlowStyle.resolve({"preset": "sankey", "scale": "log", "min_px": 0.5})
	var l1 := GraphFlowStyle.width_px(lg, 1.0, 100.0, true, 1.0)
	var l2 := GraphFlowStyle.width_px(lg, 10.0, 100.0, true, 1.0)
	var l3 := GraphFlowStyle.width_px(lg, 100.0, 100.0, true, 1.0)
	_ok(l1 < l2 and l2 < l3 and is_equal_approx(l3, float(lg["thickness"])), "log: monotone, reference full")
	var z_world := GraphFlowStyle.width_px(st, 100.0, 100.0, true, 2.0)
	var z_far := GraphFlowStyle.width_px(st, 100.0, 100.0, true, 0.1)
	_ok(is_equal_approx(z_world, full * 2.0) and is_equal_approx(z_far, full * float(st["zoom_floor"])),
		"graph widths scale with zoom, floored when zoomed far out")
	var bold := GraphFlowStyle.resolve({"preset": "bold"})
	_ok(is_equal_approx(GraphFlowStyle.width_px(bold, 100.0, 100.0, true, 0.25),
		GraphFlowStyle.width_px(bold, 100.0, 100.0, true, 1.0)), "screen-space widths ignore zoom")


func _test_overrides() -> void:
	var st := GraphFlowStyle.resolve({"preset": "sankey"})
	var base := GraphFlowStyle.width_px(st, 40.0, 100.0, true, 1.0)
	_ok(is_equal_approx(GraphFlowStyle.width_px(st, 40.0, 100.0, true, 1.0, GraphFlowStyle.WIRE_EMPHASIS),
		base * 2.0), "emphasis doubles the width")
	var plain_a := GraphFlowStyle.width_px(st, 5.0, 100.0, true, 1.0, GraphFlowStyle.WIRE_PLAIN)
	var plain_b := GraphFlowStyle.width_px(st, 95.0, 100.0, true, 1.0, GraphFlowStyle.WIRE_PLAIN)
	_ok(is_equal_approx(plain_a, plain_b), "plain wires do not follow flow")
	_ok(GraphFlowStyle.wire_override({"sankey_scale": false}) == GraphFlowStyle.WIRE_PLAIN,
		"old sankey_scale false migrates to plain")
	_ok(GraphFlowStyle.wire_override({"sankey_scale": true}) == GraphFlowStyle.WIRE_INHERIT
		and GraphFlowStyle.wire_override({}) == GraphFlowStyle.WIRE_INHERIT, "true / missing inherit")
	_ok(GraphFlowStyle.wire_override({"sankey_scale": false, "flow_width": "x2"}) == GraphFlowStyle.WIRE_EMPHASIS,
		"a new override wins over the old key")


func _test_motion() -> void:
	var st := GraphFlowStyle.resolve({"preset": "sankey"})
	var s_small := GraphFlowStyle.anim_speed_px(st, 1.0, 100.0)
	var s_big := GraphFlowStyle.anim_speed_px(st, 100.0, 100.0)
	var s_huge := GraphFlowStyle.anim_speed_px(st, 1e9, 100.0)
	_ok(s_big > s_small and s_small > 0.0, "more flow moves faster")
	_ok(s_huge <= GraphFlowStyle.MAX_ANIM_PX_S + 1e-3, "speed is capped below strobing")
	_ok(GraphFlowStyle.anim_speed_px(st, 0.0, 100.0) == 0.0, "nothing flowing, nothing moves")
	# A forward pattern travels toward +s: the bright head found at s at time
	# t is found further along at a later time.
	var sp := 40.0
	var hi_t0 := _brightest_s(GraphFlowStyle.ANIM_STREAKS, 0.0, sp, false)
	var hi_t1 := _brightest_s(GraphFlowStyle.ANIM_STREAKS, 0.25, sp, false)
	_ok(fposmod(hi_t1 - hi_t0, 44.0) > 5.0 and fposmod(hi_t1 - hi_t0, 44.0) < 15.0,
		"streaks move forward at the asked speed")
	var r0 := _brightest_s(GraphFlowStyle.ANIM_STREAKS, 0.0, sp, true)
	var r1 := _brightest_s(GraphFlowStyle.ANIM_STREAKS, 0.25, sp, true)
	_ok(fposmod(r0 - r1, 44.0) > 5.0 and fposmod(r0 - r1, 44.0) < 15.0, "reversed streaks move backward")
	var v := GraphFlowStyle.pattern(GraphFlowStyle.ANIM_COMETS, 30.0, 1e6, sp, false)
	_ok(v >= 0.0 and v <= 1.0, "a pattern after a long run stays in 0..1 (no wrap jump)")
	_ok(GraphFlowStyle.pattern(GraphFlowStyle.ANIM_NONE, 3.0, 1.0, sp, false) == 0.0, "still means still")


func _brightest_s(anim: String, t: float, speed: float, rev: bool) -> float:
	var best := -1.0
	var at := 0.0
	var s := 0.0
	while s < 44.0:
		var v := GraphFlowStyle.pattern(anim, s, t, speed, rev)
		if v > best:
			best = v
			at = s
		s += 0.25
	return at


func _test_easing() -> void:
	var up := GraphFlowStyle.ease_ref(10.0, 100.0, 0.5)
	var down := GraphFlowStyle.ease_ref(100.0, 10.0, 0.5)
	_ok(up > 90.0, "the reference rises fast to a new peak")
	_ok(down > 60.0, "the reference falls slowly")
	_ok(GraphFlowStyle.ease_ref(0.0, 50.0, 0.1) == 50.0, "a first reference takes the frame max")
	# Exact averaging: two half steps == one whole step.
	var one := GraphFlowStyle.ease_rate(0.0, 10.0, 1.0, 2.0)
	var two := GraphFlowStyle.ease_rate(GraphFlowStyle.ease_rate(0.0, 10.0, 0.5, 2.0), 10.0, 0.5, 2.0)
	_ok(is_equal_approx(one, two), "averaging is exact for any step")
	_ok(GraphFlowStyle.ease_rate(3.0, 10.0, 1.0, 0.0) == 10.0, "no averaging = instantaneous")


func _test_legend() -> void:
	var t: Array = GraphFlowStyle.legend_tick(943.0)
	_ok(is_equal_approx(float(t[0]), 500.0) and float(t[1]) <= 1.0, "legend picks a round value under the ref")
	var t2: Array = GraphFlowStyle.legend_tick(2.0)
	_ok(is_equal_approx(float(t2[0]), 2.0), "an exact round ref is its own tick")
	_ok(GraphFlowStyle.scale_key(false, "") == "electricity"
		and GraphFlowStyle.scale_key(true, "water") == "water", "each resource keeps its own scale key")


func _test_ribbon_geometry() -> void:
	var path := PackedVector2Array([Vector2(0, 0), Vector2(300, 0)])
	var r := GraphFlowRibbons.build(path, {"width": 20.0, "color": Color.CYAN, "active": false})
	_ok(not r.is_empty(), "a ribbon builds")
	var pts: PackedVector2Array = r["pts"]
	var maxy := 0.0
	for p in pts:
		maxy = maxf(maxy, absf(p.y))
	_ok(is_equal_approx(maxy, 10.0), "body is exactly the asked width (no glow when idle)")
	_ok(int(r["samples"]) >= 300 / int(GraphFlowRibbons.STEP_PX), "samples every few px")
	var lit := GraphFlowRibbons.build(path, {"width": 20.0, "color": Color.CYAN, "active": true, "glow": 1.0})
	var maxg := 0.0
	for p in (lit["pts"] as PackedVector2Array):
		maxg = maxf(maxg, absf(p.y))
	_ok(maxg > 10.0, "a live ribbon has a glow wider than its body")
	var corner := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100)])
	var rc := GraphFlowRibbons.build(corner, {"width": 10.0, "color": Color.WHITE, "active": false})
	var far := 0.0
	var on_path := PackedVector2Array(GraphFlowRibbons.resample(corner, 6.0)["pts"])
	for p in (rc["pts"] as PackedVector2Array):
		var best := INF
		for q in on_path:
			best = minf(best, p.distance_to(q))
		far = maxf(far, best)
	_ok(far <= 5.0 * GraphFlowRibbons.MITER_LIMIT + 0.01, "a sharp corner never spikes past the miter limit")
	_ok(GraphFlowRibbons.build(PackedVector2Array([Vector2.ZERO]), {}).is_empty(), "a one-point path draws nothing")

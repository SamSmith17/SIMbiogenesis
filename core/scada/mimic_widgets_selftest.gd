extends SceneTree
## Dashboard widgets and screens (SCADA plan, Phase 8), offline:
##   Godot --headless --path . --script core/scada/mimic_widgets_selftest.gd
## MimicWidgets (make / clean / screens / state / press), the lens's scale
## text parser, the hub's pens, and the scripts that draw them compile.

const EXPECTED_CHECKS := 74

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	_test_make_and_clean()
	_test_screens()
	_test_state()
	_test_press()
	_test_scripts()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: expected %d checks, ran %d (a test function aborted?)" % [EXPECTED_CHECKS, _checks])
	print("MIMIC WIDGETS SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAILED", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _test_make_and_clean() -> void:
	for k in MimicWidgets.KINDS:
		_check(MimicWidgets.KIND_WORDS.has(k) and MimicWidgets.KIND_TIPS.has(k) and MimicWidgets.SIZES.has(k), "%s has words, a tip and a size" % k)
	var w := MimicWidgets.make("w1", "gauge", Vector2(10, 20))
	_check(str(w["kind"]) == "gauge" and float(w["x"]) == 10.0 and float(w["w"]) == 150.0, "make: a gauge at its default size")
	_check(str(MimicWidgets.make("w2", "nonsense", Vector2.ZERO)["kind"]) == "value", "make: an unknown kind is a number")
	var n := MimicWidgets.normalized({"id": "a", "kind": "bar", "w": 99999.0, "h": 1.0, "label": "x".repeat(200)})
	_check(float(n["w"]) == 60.0 * MimicWidgets.SIZE_MAX and float(n["h"]) == 150.0 * MimicWidgets.SIZE_MIN, "normalized: size clamped to the kind's range")
	_check(str(n["label"]).length() == 60, "normalized: label capped")
	var d := MimicWidgets.clean(null)
	_check(MimicWidgets.is_default(d), "clean(null) = one Overview screen with the picture")
	_check(MimicWidgets.is_default(MimicWidgets.clean({})) and MimicWidgets.is_default(MimicWidgets.clean({"screens": "x"})), "clean of an empty or wrong-shaped dict is the default too")
	var dirty := {"screens": [
		{"id": "s1", "name": "", "picture": true, "widgets": [w, w.duplicate(), {"id": "", "kind": "lamp"}, "junk"]},
		{"id": "s1", "name": "dup"}, "junk", {"id": "s2", "name": "  Board  ", "widgets": [MimicWidgets.make("w9", "lamp", Vector2.ZERO)]}]}
	var c := MimicWidgets.clean(dirty)
	_check((c["screens"] as Array).size() == 2, "clean: duplicate screen ids and junk dropped")
	_check((c["screens"][0]["widgets"] as Array).size() == 1, "clean: duplicate and id-less widgets dropped")
	_check(str(c["screens"][0]["name"]) == "Screen" and str(c["screens"][1]["name"]) == "Board", "clean: names trimmed, empty named")
	_check(not bool(c["screens"][1]["picture"]), "clean: a screen without `picture` is a board")
	_check(not MimicWidgets.is_default(c), "a cleaned doc with widgets is not the default")
	var many := {"screens": []}
	for i in 20:
		(many["screens"] as Array).append({"id": "s%d" % i, "name": "S", "widgets": []})
	_check((MimicWidgets.clean(many)["screens"] as Array).size() == MimicWidgets.MAX_SCREENS, "clean: screens capped")
	var crowd := {"screens": [{"id": "s1", "name": "S", "widgets": []}]}
	for i in 200:
		(crowd["screens"][0]["widgets"] as Array).append(MimicWidgets.make("w%d" % i, "value", Vector2.ZERO))
	_check((MimicWidgets.clean(crowd)["screens"][0]["widgets"] as Array).size() == MimicWidgets.MAX_WIDGETS, "clean: widgets capped")
	# JSON round trip keeps everything.
	var back: Variant = JSON.parse_string(JSON.stringify(c))
	_check(JSON.stringify(MimicWidgets.clean(back)) == JSON.stringify(c), "clean(JSON round trip) is unchanged")
	var e := MimicWidgets.element(w)
	_check(str(e["id"]) == "w:w1" and str(e["kind"]) == "widget" and str(e["wkind"]) == "gauge" and (e["size"] as Vector2) == Vector2(150, 120), "element: a doc element with a w: id")
	_check(MimicWidgets.is_widget_id("w:w1") and not MimicWidgets.is_widget_id("tank_1") and MimicWidgets.widget_id("w:w1") == "w1", "widget ids")


func _test_screens() -> void:
	var d := MimicWidgets.default_data()
	_check(MimicWidgets.new_screen_id(d) == "s2" and MimicWidgets.new_widget_id(d) == "w1", "new ids skip the used ones")
	(d["screens"] as Array).append({"id": "s2", "name": "Trends", "picture": false, "widgets": []})
	(d["screens"][0]["widgets"] as Array).append(MimicWidgets.make("w1", "nav", Vector2.ZERO))
	d["screens"][0]["widgets"][0]["screen"] = "s2"
	(d["screens"][1]["widgets"] as Array).append(MimicWidgets.make("w2", "trend", Vector2.ZERO))
	_check(MimicWidgets.new_widget_id(d) == "w3", "widget ids are unique across screens")
	_check(str(MimicWidgets.screen(d, "s2")["name"]) == "Trends" and str(MimicWidgets.screen(d, "gone")["id"]) == "s1", "screen(): by id, else the first")
	_check(str(MimicWidgets.find(d, "w2")["kind"]) == "trend" and MimicWidgets.find(d, "nope").is_empty(), "find across screens")
	_check(MimicWidgets.remove_screen(d, "s2") and (d["screens"] as Array).size() == 1, "remove a screen")
	_check(str(d["screens"][0]["widgets"][0]["screen"]) == "", "a nav button that pointed at it loses its target")
	_check(not MimicWidgets.remove_screen(d, "s1"), "the last screen stays")
	MimicWidgets.remove(d, "w1")
	_check((d["screens"][0]["widgets"] as Array).is_empty(), "remove a widget")


func _test_state() -> void:
	var vals := {"tank.a.level": 42.0, "node.p": 1.0, "site.kw": 3.2, "gone": NAN}
	var infos := {"tank.a.level": {"label": "Tank A level", "unit": "%"}, "node.p": {"label": "Pump", "binary": true, "writable": true},
		"site.kw": {"label": "Solar", "unit": "kW"}, "valve.v.open": {"label": "Valve", "unit": "%", "writable": true, "lo": 0.0, "hi": 100.0}}
	var read := func(t: String) -> float: return float(vals.get(t, NAN))
	var info := func(t: String) -> Dictionary: return infos.get(t, {"label": t, "available": false})
	var trend := func(_t: String) -> PackedFloat32Array: return PackedFloat32Array([10.0, NAN, 20.0, 30.0])
	var sname := func(sid: String) -> String: return "Trends" if sid == "s2" else ""
	var g := MimicWidgets.make("g", "gauge", Vector2.ZERO)
	var st := MimicWidgets.state(g, read, info, trend, sname)
	_check(not bool(st["bound"]) and str(st["text"]) == "Pick a tag", "an unbound widget says so")
	g["tag"] = "tank.a.level"
	st = MimicWidgets.state(g, read, info, trend, sname)
	_check(bool(st["avail"]) and str(st["label"]) == "Tank A level" and str(st["text"]) == "42.0 %", "gauge: the tag's name and reading")
	_check(float(st["lo"]) == 0.0 and float(st["hi"]) == 100.0 and absf(float(st["frac"]) - 0.42) < 1e-6, "a % tag scales 0 to 100")
	g["lo"] = 40.0
	g["hi"] = 50.0
	g["label"] = "My tank"
	st = MimicWidgets.state(g, read, info, trend, sname)
	_check(absf(float(st["frac"]) - 0.2) < 1e-6 and str(st["label"]) == "My tank", "its own scale and name win")
	var kw := MimicWidgets.make("k", "value", Vector2.ZERO)
	kw["tag"] = "site.kw"
	st = MimicWidgets.state(kw, read, info, trend, sname)
	_check(str(st["text"]) == "3.20 kW" and float(st["hi"]) == 5.0, "a number with no scale gets a round one above it (3.2 → 5)")
	var lamp := MimicWidgets.make("l", "lamp", Vector2.ZERO)
	lamp["tag"] = "node.p"
	st = MimicWidgets.state(lamp, read, info, trend, sname)
	_check(bool(st["on"]) and str(st["text"]) == "On" and bool(st["writable"]), "lamp: an on / off tag reads On")
	lamp["tag"] = "gone"
	st = MimicWidgets.state(lamp, read, info, trend, sname)
	_check(not bool(st["avail"]) and not bool(st["on"]) and str(st["text"]) == "no reading", "no reading: not available, not on")
	var tr := MimicWidgets.make("t", "trend", Vector2.ZERO)
	tr["tag"] = "site.kw"
	st = MimicWidgets.state(tr, read, info, trend, sname)
	_check((st["trend"] as PackedFloat32Array).size() == 4, "trend: carries its samples")
	_check(float(st["lo"]) < 10.0 and float(st["hi"]) > 30.0 and float(st["lo"]) > 0.0, "trend: scaled to its data with a margin")
	var sl := MimicWidgets.make("s", "slider", Vector2.ZERO)
	sl["tag"] = "valve.v.open"
	st = MimicWidgets.state(sl, read, info, trend, sname)
	_check(float(st["hi"]) == 100.0 and not bool(st["avail"]), "slider: the tag's own range; no reading yet")
	var tx := MimicWidgets.make("x", "text", Vector2.ZERO)
	tx["text"] = "Water plant"
	_check(str(MimicWidgets.state(tx, read, info, trend, sname)["text"]) == "Water plant", "text shows its words")
	var nav := MimicWidgets.make("n", "nav", Vector2.ZERO)
	_check(str(MimicWidgets.state(nav, read, info, trend, sname)["text"]) == "Pick a screen", "nav with no target says so")
	nav["screen"] = "s2"
	_check(str(MimicWidgets.state(nav, read, info, trend, sname)["text"]) == "Trends", "nav shows its screen's name")
	_check(MimicWidgets.fmt(1234.6) == "1235" and MimicWidgets.fmt(123.4) == "123" and MimicWidgets.fmt(12.34) == "12.3" and MimicWidgets.fmt(1.234) == "1.23", "fmt: about three figures")
	_check(MimicWidgets.scale_of({"lo": 0.0, "hi": 0.0}, "", true, 1.0) == Vector2(0, 1), "scale: on / off is 0 to 1")
	_check(MimicWidgets.scale_of({"lo": 0.0, "hi": 0.0}, "L", false, 730.0) == Vector2(0, 1000), "scale: 730 → 0 to 1000")
	_check(MimicWidgets.scale_of({"lo": 0.0, "hi": 0.0}, "L", false, NAN) == Vector2(0, 100), "scale: no reading → 0 to 100")


func _test_press() -> void:
	var b := MimicWidgets.make("b", "button", Vector2.ZERO)
	_check(MimicWidgets.press(b, {}, 0.0).is_empty(), "an unbound button does nothing")
	b["tag"] = "node.p"
	_check(float(MimicWidgets.press(b, {"on": false}, 0.0)["value"]) == 1.0, "button: off → on")
	_check(float(MimicWidgets.press(b, {"on": true}, 0.0)["value"]) == 0.0, "button: on → off")
	var s := MimicWidgets.make("s", "slider", Vector2.ZERO)
	s["tag"] = "valve.v.open"
	var a := MimicWidgets.press(s, {"lo": 0.0, "hi": 100.0}, 0.374)
	_check(str(a["tag"]) == "valve.v.open" and float(a["value"]) == 37.0, "slider: 37.4 % along a 0-100 scale → 37")
	_check(float(MimicWidgets.press(s, {"lo": 0.0, "hi": 10.0}, 0.374)["value"]) == 3.7, "slider: tenths on a narrow scale")
	_check(float(MimicWidgets.press(s, {"lo": 0.0, "hi": 100.0}, 7.0)["value"]) == 100.0, "slider: clamped to its scale")
	var n := MimicWidgets.make("n", "nav", Vector2.ZERO)
	_check(MimicWidgets.press(n, {}, 0.0).is_empty(), "nav with no target does nothing")
	n["screen"] = "s2"
	_check(str(MimicWidgets.press(n, {}, 0.0)["screen"]) == "s2", "nav: go to its screen")
	_check(MimicWidgets.press(MimicWidgets.make("g", "gauge", Vector2.ZERO), {}, 0.0).is_empty(), "a gauge is not pressed")
	# The slider's track: the drawing and the click agree.
	var r := Rect2(100, 50, 220, 56)
	_check(MimicSymbols.slider_frac(r, 100.0) == 0.0 and MimicSymbols.slider_frac(r, 320.0) == 1.0, "slider track: ends clamp")
	_check(absf(MimicSymbols.slider_frac(r, 210.0) - 0.5) < 1e-6, "slider track: the middle is half")


func _test_scripts() -> void:
	for p in ["res://scenes/ui/scada/mimic_canvas.gd", "res://scenes/ui/kit/trend_chart.gd", "res://scenes/ui/scada/trend_window.gd",
			"res://system_graph/graph_process_lens.gd"]:
		var sc: Variant = load(p)
		_check(sc is GDScript and (sc as GDScript).can_instantiate(), "%s compiles" % p.get_file())
	var lens: GDScript = load("res://system_graph/graph_process_lens.gd")
	_check(lens.call("parse_range", "0 to 100") == {"lo": 0.0, "hi": 100.0}, "scale text: \"0 to 100\"")
	_check(lens.call("parse_range", "-5, 12.5") == {"lo": -5.0, "hi": 12.5}, "scale text: \"-5, 12.5\"")
	_check(lens.call("parse_range", "") == {"lo": 0.0, "hi": 0.0} and lens.call("parse_range", "9 to 3") == {"lo": 0.0, "hi": 0.0}, "scale text: empty or backwards = automatic")
	_check(TrendChart.ago_text(0.0) == "now" and TrendChart.ago_text(0.5) == "30 min ago" and TrendChart.ago_text(3.0) == "3.0 h ago" and TrendChart.ago_text(72.0) == "3.0 days ago", "trend axis words")
	_check(TrendChart.value_text(NAN, "%", false) == "no reading" and TrendChart.value_text(1.0, "", true) == "On" and TrendChart.value_text(42.0, "%", false) == "42.0 %", "trend legend words")
	# The chart scales pens of one unit together.
	var ch := TrendChart.new()
	ch.size = Vector2(600, 300)
	ch.fetch = func(id: String, _a: float, _b: float, n: int) -> PackedFloat32Array:
		var o := PackedFloat32Array()
		for i in n:
			o.append((10.0 if id == "a" else 500.0) + float(i))
		return o
	ch.now_fn = func() -> float: return 100.0
	ch.pens = [{"id": "a", "unit": "L", "color": Color.WHITE}, {"id": "b", "unit": "L", "color": Color.WHITE}, {"id": "c", "unit": "kW", "color": Color.WHITE}, {"id": "d", "binary": true, "color": Color.WHITE}]
	ch.refresh()
	_check(ch.scale_of(0) == ch.scale_of(1) and ch.scale_of(0).x < 10.0 and ch.scale_of(0).y > 500.0, "chart: pens of one unit share a scale")
	_check(ch.scale_of(2) != ch.scale_of(0) and ch.scale_of(3) == Vector2(-0.15, 1.15), "chart: another unit has its own; on / off pens 0 to 1")
	_check(ch.time_range() == Vector2(98.0, 100.0) and ch.following(), "chart: the last 2 h, following now")
	var cur := ch.cursor_at(ch.plot_rect().position.x)
	_check(absf(float(cur["t"]) - 98.0) < 1e-6 and float(cur["values"][0]) == 10.0, "chart: the cursor reads every pen at its instant")
	ch.free()

extends SceneTree

## Offline selftest for the feature tour (core/tour/).
##
## Run: Godot.exe.exe --headless --path . --script core/tour/tour_selftest.gd
##
## The tour is only as good as its stops' metadata — the title card, the
## "How to open" line in docs/FEATURES.md and the README gallery all read it —
## so every stop file is loaded the way the director loads it and checked:
## it extends TourStop, has a unique id, a title / summary / how / blurb, a
## known chapter and world, a sane budget and hour, and an `action` that
## exists in project.godot's [input] (a renamed action would otherwise print
## "Press " on the card with no key). It also pins the catalogue's filters
## and the key-label formatting.
##
## Checks scale with the number of stops, so the expected total is
## FIXED_CHECKS + PER_STOP_CHECKS × stops: a runtime error that aborts a test
## function leaves the count short and fails the suite even though PASS lines
## printed (the trap EXPECTED_CHECKS exists for elsewhere).

const FIXED_CHECKS := 19
const PER_STOP_CHECKS := 10

var _checks := 0
var _fails := 0


func _initialize() -> void:
	var stops := _test_stops()
	_test_select(stops)
	_test_labels()
	_test_template()
	var expected := FIXED_CHECKS + PER_STOP_CHECKS * stops.size()
	_check(_checks + 1 == expected, "check count %d == expected %d" % [_checks + 1, expected])
	print("tour_selftest: %d checks, %d failed — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s" % what)


func _test_stops() -> Array:
	var paths := TourCatalog.stop_paths()
	_check(paths.size() >= 20, "at least 20 stops found (%d)" % paths.size())
	var sorted := paths.duplicate()
	sorted.sort()
	_check(sorted == paths, "stop paths come back in file order")
	var ids := {}
	var stops: Array = []
	for p in paths:
		var s := TourCatalog.load_stop(p)
		_check(s != null, "%s loads as a TourStop" % p)
		if s == null:
			# Keep the count honest for the per-stop checks this stop skips.
			for _i in PER_STOP_CHECKS - 1:
				_check(false, "%s skipped" % p)
			continue
		stops.append(s)
		var stem := p.get_file().get_basename()
		_check(stem.ends_with("_" + s.id), "%s: id '%s' matches the file name" % [p, s.id])
		_check(not ids.has(s.id), "%s: id '%s' is unique" % [p, s.id])
		ids[s.id] = true
		_check(not s.title.is_empty() and not s.summary.is_empty(), "%s: title and summary set" % s.id)
		_check(s.how.size() >= 1 and not s.how[0].is_empty(), "%s: at least one 'how' step" % s.id)
		_check(s.blurb.length() >= 60, "%s: a docs blurb (%d chars)" % [s.id, s.blurb.length()])
		_check(s.chapter in TourStop.CHAPTERS, "%s: chapter '%s' is known" % [s.id, s.chapter])
		_check(HarnessRegistry.WORLD_ALIASES.has(s.world), "%s: world '%s' is a harness world" % [s.id, s.world])
		_check(s.budget_s >= 10.0 and s.budget_s <= 180.0, "%s: budget %.0f s in range" % [s.id, s.budget_s])
		var action_ok := s.action.is_empty() or ProjectSettings.has_setting("input/" + s.action)
		var has_way := not s.action.is_empty() or not s.button.is_empty()
		_check(action_ok and has_way and (is_nan(s.hour) or (s.hour >= 0.0 and s.hour <= 24.0)),
			"%s: action '%s' exists in [input], an action or button is named, hour valid" % [s.id, s.action])
	# Chapters appear in TourStop.CHAPTERS order through the file order.
	var last := -1
	var ordered := true
	for s0 in stops:
		var ci := TourStop.CHAPTERS.find((s0 as TourStop).chapter)
		if ci < last:
			ordered = false
		last = maxi(last, ci)
	_check(ordered, "file order keeps chapters together in CHAPTERS order")
	return stops


func _test_select(stops: Array) -> void:
	var all := TourCatalog.select(stops, PackedStringArray(), PackedStringArray(), "", false)
	var n_opt := stops.filter(func(s: TourStop) -> bool: return s.optional).size()
	_check(all.size() == stops.size() - n_opt, "default selection drops only optional stops")
	var with_opt := TourCatalog.select(stops, PackedStringArray(), PackedStringArray(), "", true)
	_check(with_opt.size() == stops.size(), "include_optional keeps everything")
	var first := stops[0] as TourStop
	var one := TourCatalog.select(stops, PackedStringArray([first.id.to_upper()]), PackedStringArray(), "", false)
	_check(one.size() == 1 and (one[0] as TourStop).id == first.id, "selecting by id (case-insensitive) picks one stop")
	var w := TourCatalog.select(stops, PackedStringArray(), PackedStringArray(), "walton", true)
	_check(w.all(func(s: TourStop) -> bool: return s.world == "walton"), "a world filter keeps that world only")
	var ch := TourCatalog.select(stops, PackedStringArray(), PackedStringArray(["systems"]), "", true)
	_check(not ch.is_empty() and ch.all(func(s: TourStop) -> bool: return s.chapter == "Systems"),
		"a chapter filter keeps that chapter only")
	var opt_named: Array = stops.filter(func(s: TourStop) -> bool: return s.optional)
	if opt_named.is_empty():
		_check(true, "no optional stop to name")
	else:
		var sel := TourCatalog.select(stops, PackedStringArray([(opt_named[0] as TourStop).id]), PackedStringArray(), "", false)
		_check(sel.size() == 1, "naming an optional stop selects it")
	var worlds := TourCatalog.worlds_of(stops)
	_check(worlds.size() >= 1 and worlds[0] == (stops[0] as TourStop).world, "worlds_of lists first-use order")


func _test_labels() -> void:
	var k := InputEventKey.new()
	k.physical_keycode = KEY_G
	_check(HarnessInput.event_label(k) == "G", "a plain key reads 'G' (got '%s')" % HarnessInput.event_label(k))
	var ks := InputEventKey.new()
	ks.physical_keycode = KEY_T
	ks.shift_pressed = true
	_check(HarnessInput.event_label(ks) == "Shift+T", "a shifted key reads 'Shift+T'")
	var kf := InputEventKey.new()
	kf.keycode = KEY_F5
	_check(HarnessInput.event_label(kf) == "F5", "a keycode-only key still labels (F5)")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_RIGHT
	_check(HarnessInput.event_label(mb) == "Right click", "a mouse button labels")
	var s := TourStop.new()
	s.action = ""
	s.button = "📊"
	var hints := TourContext.open_hints(s)
	_check(hints.size() == 1 and hints[0] == "Click 📊", "a button-only stop hints 'Click 📊'")
	_check(HarnessInput.action_label("definitely_not_an_action") == "", "an unknown action labels empty")


func _test_template() -> void:
	var t := load("%s/%s" % [TourCatalog.STOPS_DIR, TourCatalog.TEMPLATE_FILE]) as Script
	_check(t != null and t.new() is TourStop, "the template loads as a TourStop")
	var listed := false
	for p in TourCatalog.stop_paths():
		if p.get_file() == TourCatalog.TEMPLATE_FILE:
			listed = true
	_check(not listed, "the template is not a stop")

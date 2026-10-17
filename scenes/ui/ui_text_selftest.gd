extends SceneTree

## Offline selftest for the UI foundation: UiText (plurals, numbers, durations,
## fit), UiIcons (every generated icon renders; unknown names are null) and
## UiThemeBuilder (the Theme builds, Inter loads, the auto scale curve).
##
## Run: Godot.exe.exe --headless --path . --script scenes/ui/ui_text_selftest.gd
## Carries EXPECTED_CHECKS: a runtime error aborts a test function while the
## suite would still print PASS.

const EXPECTED_CHECKS := 49

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_plural()
	_test_numbers()
	_test_duration()
	_test_fit()
	_test_icons()
	_test_theme()
	_check(_checks + 1 == EXPECTED_CHECKS, "check count %d == EXPECTED_CHECKS %d" % [_checks + 1, EXPECTED_CHECKS])
	print("ui_text_selftest: %d checks, %d failed — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s: got '%s', want '%s'" % [what, str(got), str(want)])


func _test_plural() -> void:
	_eq(UiText.count(1, "day"), "1 day", "singular")
	_eq(UiText.count(3, "day"), "3 days", "plural")
	_eq(UiText.count(0, "occupant"), "0 occupants", "zero is plural")
	_eq(UiText.count(1, "person"), "1 person", "irregular singular")
	_eq(UiText.count(12, "person"), "12 people", "irregular plural")
	_eq(UiText.count(2, "battery"), "2 batteries", "consonant + y")
	_eq(UiText.count(2, "day"), "2 days", "vowel + y keeps y")
	_eq(UiText.count(4, "box"), "4 boxes", "x takes es")
	_eq(UiText.count(2, "bus"), "2 buses", "s takes es")
	_eq(UiText.count(1204, "person"), "1,204 people", "thousands separator in counts")
	_eq(UiText.plural(2, "cactus"), "cacti", "irregular table")
	_eq(UiText.plural(2, "leaf", "leaves"), "leaves", "explicit plural form")


func _test_numbers() -> void:
	_eq(UiText.thousands(1473946), "1,473,946", "thousands")
	_eq(UiText.thousands(-1500), "-1,500", "negative thousands")
	_eq(UiText.thousands(999), "999", "no separator under 1000")
	_eq(UiText.num(2843.0, "W"), "2.84 kW", "SI kilo")
	_eq(UiText.num(20800.0, "Wh"), "20.8 kWh", "SI kilo Wh")
	_eq(UiText.num(96600000.0, "W"), "96.6 MW", "SI mega")
	_eq(UiText.num(0.7512, "m"), "0.75 m", "small value, 2 decimals max")
	_eq(UiText.num(39.12, "m"), "39.1 m", "3 significant")
	_eq(UiText.num(1405.0, "rpm"), "1,405 rpm", "non-SI unit keeps thousands")
	_eq(UiText.num(1473946.5, "L"), "1.47 ML", "litres take SI above 10 k")
	_eq(UiText.num(2179.0, "L"), "2,179 L", "litres stay plain below 10 k")
	_eq(UiText.num(2.0, "kW"), "2 kW", "trailing zeros trimmed")
	_eq(UiText.num(NAN, "W"), "—", "NaN reads a dash")
	_eq(UiText.pct(0.4231), "42%", "percent")
	_eq(UiText.pct(0.0425, 1), "4.3%", "percent with a decimal")
	_eq(UiText.from_id("siphon_hydro"), "Siphon hydro", "display name from an id")


func _test_duration() -> void:
	_eq(UiText.duration(0.5), "30 min", "minutes")
	_eq(UiText.duration(0.005), "18 s", "seconds")
	_eq(UiText.duration(2.5), "2.5 h", "hours")
	_eq(UiText.duration(24.0), "24 h", "a day still in hours")
	_eq(UiText.duration(72.0), "3 days", "days")
	_eq(UiText.duration(24.0 * 21.0), "3 weeks", "weeks")


func _test_fit() -> void:
	var f := ThemeDB.fallback_font
	var long := "buckets at 46% of the jet · runaway 3054 rpm"
	var fitted := UiText.fit(f, long, 12, 120.0)
	_check(fitted.ends_with(UiText.ELLIPSIS), "a long line is ellipsized")
	_check(f.get_string_size(fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x <= 120.0, "the fitted line fits")
	_eq(UiText.fit(f, "short", 12, 400.0), "short", "a line that fits is unchanged")
	UiAudit.reset_canvas_truncations()
	UiText.fit(f, long, 12, 60.0, "test.site")
	var res := UiAudit.run(root)
	_eq(((res.get("canvas_truncated", {}) as Dictionary).get("test.site", []) as Array).size(), 1, "truncation reported to the audit")


func _test_icons() -> void:
	var names: Array = UiIconData.ICONS.keys()
	_check(names.size() >= 80, "at least 80 icons compiled (%d)" % names.size())
	var bad := 0
	for n in names:
		var t := UiIcons.icon(n, 16)
		if t == null or t.get_width() != 16:
			bad += 1
	_eq(bad, 0, "every icon renders at 16 px")
	_check(UiIcons.icon("zap", 32).get_width() == 32, "an icon renders at another size")
	_check(UiIcons.icon("zap", 16) == UiIcons.icon("zap", 16), "icons are cached")
	_check(UiIcons.icon("no-such-icon") == null, "an unknown icon is null")


func _test_theme() -> void:
	var t := UITheme.build_theme()
	_check(t != null and t.default_font != null, "the Theme builds with a default font")
	_check(UITheme.font("semibold") != null, "Inter SemiBold loads")
	_check(t.has_stylebox("panel", "PopupMenu") and t.has_stylebox("tab_selected", "TabContainer"),
		"stock popups and tabs are styled")
	_eq(UiThemeBuilder.auto_scale(1080.0), 1.0, "auto scale at 1080p")
	_eq(UiThemeBuilder.auto_scale(720.0), 1.25, "auto scale at 720p")

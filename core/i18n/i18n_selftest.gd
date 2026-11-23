extends SceneTree

## Offline selftest for localization (plans/LOCALIZATION_PLAN.md):
## LocaleFormat (grouping incl. India's 3-2, decimal marks, percent), I18n
## (a raw .po loading at runtime, context, every Arabic plural form, named
## placeholders, best_match of OS locales, harness runs forced to English),
## the shipped pseudo-locales loading and covering the POT, and UiText still
## writing English exactly as before.
##
## Run: Godot.exe.exe --headless --path . --script core/i18n/i18n_selftest.gd
## Carries EXPECTED_CHECKS (a runtime error aborts a test function while PASS
## would still print).

const EXPECTED_CHECKS := 47

var _checks := 0
var _fails := 0


func _initialize() -> void:
	I18n.reset_for_test()
	_test_format()
	_test_uitext_english()
	_test_runtime_po()
	_test_best_match()
	_test_pseudo()
	I18n.reset_for_test()
	_check(_checks + 1 == EXPECTED_CHECKS, "check count %d == EXPECTED_CHECKS %d" % [_checks + 1, EXPECTED_CHECKS])
	print("i18n_selftest: %d checks, %d failed — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s: got '%s', want '%s'" % [what, str(got), str(want)])


func _test_format() -> void:
	_eq(LocaleFormat.integer(1473946, "en"), "1,473,946", "en grouping")
	_eq(LocaleFormat.integer(1473946, "de"), "1.473.946", "de grouping")
	_eq(LocaleFormat.integer(1473946, "hi"), "14,73,946", "hi grouping 3-2")
	_eq(LocaleFormat.integer(1234, "es"), "1234", "es leaves 4 digits")
	_eq(LocaleFormat.integer(12345, "es"), "12.345", "es groups 5 digits")
	_eq(LocaleFormat.integer(-1234, "en"), "-1,234", "negative")
	_eq(LocaleFormat.decimal(3.5, 2, "en"), "3.5", "en decimal")
	_eq(LocaleFormat.decimal(3.5, 2, "de"), "3,5", "de decimal")
	_eq(LocaleFormat.decimal(12345.25, 1, "fr"), "12" + LocaleFormat.NNBSP + "345,3", "fr decimal + group")
	_eq(LocaleFormat.fixed(2.0, 2, "en"), "2.00", "fixed keeps zeros")
	_eq(LocaleFormat.percent(0.4231, 0, "en"), "42%", "en percent")
	_eq(LocaleFormat.percent(0.4231, 0, "tr"), "%42", "tr percent before")
	_eq(LocaleFormat.percent(0.5, 0, "de"), "50" + LocaleFormat.NBSP + "%", "de percent space")
	_eq(LocaleFormat.integer(1000, "pt_PT"), "1,000", "unknown region falls back by language/en")
	_eq(LocaleFormat.decimal(NAN, 2, "en"), "—", "nan")


func _test_uitext_english() -> void:
	# English output must not move: every existing screen and selftest reads it.
	_eq(UiText.thousands(1473946), "1,473,946", "UiText.thousands")
	_eq(UiText.num(0.7512, "m"), "0.75 m", "UiText.num small")
	_eq(UiText.num(2843.0, "W"), "2.84 kW", "UiText.num SI")
	_eq(UiText.pct(0.4231), "42%", "UiText.pct")
	_eq(UiText.count(1204, "person"), "1,204 people", "UiText.count")


func _test_runtime_po() -> void:
	var dir := OS.get_cache_dir().path_join("simbio_i18n_selftest")
	DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join("xx_ar.po")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("\n".join([
		'msgid ""', 'msgstr ""', '"Language: ar\\n"', '"Content-Type: text/plain; charset=UTF-8\\n"',
		'"Plural-Forms: nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);\\n"',
		'', 'msgid "Open"', 'msgstr "افتح"',
		'', 'msgctxt "door"', 'msgid "Open"', 'msgstr "مفتوح"',
		'', 'msgid "{who} is in {camp}"', 'msgstr "{camp}: {who}"',
		'', 'msgid "{n} day"', 'msgid_plural "{n} days"',
		'msgstr[0] "zero {n}"', 'msgstr[1] "one"', 'msgstr[2] "two"', 'msgstr[3] "few {n}"', 'msgstr[4] "many {n}"', 'msgstr[5] "other {n}"',
		'']))
	f.close()
	var tr_res: Variant = load(p)
	_check(tr_res is Translation, "a raw .po loads at runtime")
	if not (tr_res is Translation):
		return
	TranslationServer.add_translation(tr_res)
	TranslationServer.set_locale("ar")
	_eq(I18n.t("Open"), "افتح", "t")
	_eq(I18n.t("Open", "door"), "مفتوح", "t with context")
	_eq(I18n.t("Not in the file"), "Not in the file", "missing stays English")
	_eq(I18n.f("{who} is in {camp}", {"who": "Ana", "camp": "Sol"}), "Sol: Ana", "f reorders")
	_eq(I18n.tn("{n} day", "{n} days", 0), "zero 0", "ar plural 0")
	_eq(I18n.tn("{n} day", "{n} days", 1), "one", "ar plural 1")
	_eq(I18n.tn("{n} day", "{n} days", 2), "two", "ar plural 2")
	_eq(I18n.tn("{n} day", "{n} days", 5), "few 5", "ar plural few")
	_eq(I18n.tn("{n} day", "{n} days", 11), "many 11", "ar plural many")
	_eq(I18n.tn("{n} day", "{n} days", 100), "other 100", "ar plural other")
	_check(TextServerManager.get_primary_interface().is_locale_right_to_left("ar"), "ar is right to left")
	TranslationServer.remove_translation(tr_res)
	TranslationServer.set_locale("en")
	_eq(I18n.tn("{n} day", "{n} days", 3), "3 days", "English plural")
	_eq(I18n.tn("{n} day", "{n} days", 1), "1 day", "English singular")
	DirAccess.remove_absolute(p)


func _test_best_match() -> void:
	var have := ["en", "es", "zh_Hans", "zh_Hant", "ar", "hi", "pt_BR"]
	_eq(I18n.best_match("es_MX", have), "es", "es_MX")
	_eq(I18n.best_match("zh_CN", have), "zh_Hans", "zh_CN")
	_eq(I18n.best_match("zh_TW", have), "zh_Hant", "zh_TW")
	_eq(I18n.best_match("pt_PT", have), "pt_BR", "pt_PT")
	_eq(I18n.best_match("de_DE", have), "en", "missing -> English")
	_eq(I18n.best_match("ar_EG", have), "ar", "ar_EG")


func _test_pseudo() -> void:
	# The shipped pseudo-locales (tools/i18n/pseudo.py) load and translate.
	if not I18n.has_file("en_XA"):
		_check(false, "locale/en_XA.po missing (run python tools/i18n/update.py)")
		return
	_check("en_XA" in I18n.available(), "en_XA available")
	I18n.apply("en_XA")
	_eq(I18n.locale(), "en_XA", "applied")
	var s := I18n.t("eating")
	_check(s.begins_with("[!") and s.ends_with("!]"), "pseudo text bracketed: %s" % s)
	_check(I18nLanguages.is_rtl("ar_XB") and not I18nLanguages.is_rtl("en_XA"), "pseudo directions")
	_check(I18n.label_for("hi").contains("हिन्दी"), "label_for uses the native name")
	I18n.apply("en")
	_eq(I18n.t("eating"), "eating", "back to English")

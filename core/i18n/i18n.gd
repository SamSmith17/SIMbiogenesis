class_name I18n
extends RefCounted

## The one door to translated text (plans/LOCALIZATION_PLAN.md).
##
## English source text is the key (gettext msgid). An unwrapped string, or one
## a language has not translated yet, still reads in English.
##
##   I18n.t("Open")                          -> "Abrir"
##   I18n.t("Open", "door")                  -> a separate entry by context
##   I18n.tn("{n} day", "{n} days", 3)       -> "3 días" (every plural form)
##   I18n.f("{who} is in {camp}", {"who": a, "camp": b})
##                                           -> named placeholders a
##                                              translator can reorder
##
## Controls translate their own `text` / `tooltip_text` (Godot's
## auto_translate_mode), so a constant literal on a Label or Button needs no
## call. Formatted strings, canvas `draw_string` text, popup items built at
## runtime and data-driven text do.
##
## Static and autoload-free on purpose: pure classes and `--script` selftests
## use it (an autoload name does not compile there).
##
## Translation files: res://locale/<code>.po (shipped, written by
## tools/i18n/), or user://locale/<code>.po, which replaces the shipped one
## (a player's or volunteer's own corrections). Raw .po files load at runtime;
## nothing has to be imported.

const SOURCE := "en"
const RES_DIR := "res://locale"
const USER_DIR := "user://locale"
const PREFS_PATH := "user://ui_prefs.cfg"
const COVERAGE_PATH := "res://locale/coverage.json"
## "" = Auto (the computer's language when the game has it, else English).
const AUTO := ""

static var _pref := "<unread>"
static var _active := SOURCE
static var _loaded := {}  # code -> Translation added to the server
static var _coverage := {}
static var _coverage_read := false
static var _forced := ""  # --locale= on the command line


# --- text --------------------------------------------------------------------

static func t(msg: String, ctx: String = "") -> String:
	if msg.is_empty():
		return msg
	return String(TranslationServer.translate(msg, ctx))


## A whole phrase per plural form; `{n}` is filled with the count.
static func tn(singular: String, plural: String, n: float, ctx: String = "",
		args: Dictionary = {}) -> String:
	var k := int(round(n))
	var s := String(TranslationServer.translate_plural(singular, plural, k, ctx))
	var a := args.duplicate()
	if not a.has("n"):
		a["n"] = LocaleFormat.integer(k) if absf(n - float(k)) < 1e-9 else LocaleFormat.decimal(n, 2)
	return s.format(a)


## Translate, then fill `{name}` placeholders.
static func f(msg: String, args: Dictionary, ctx: String = "") -> String:
	return t(msg, ctx).format(args)


# --- locale ------------------------------------------------------------------

static func locale() -> String:
	return _active


static func is_rtl(code: String = "") -> bool:
	return I18nLanguages.is_rtl(_active if code.is_empty() else code)


static func script_of(code: String = "") -> String:
	return I18nLanguages.script_of(_active if code.is_empty() else code)


## The player's choice ("" = Auto).
static func pref() -> String:
	if _pref == "<unread>":
		var cfg := ConfigFile.new()
		_pref = String(cfg.get_value("ui", "locale", AUTO)) if cfg.load(PREFS_PATH) == OK else AUTO
	return _pref


## Save the choice and switch to it now. Controls re-translate themselves on
## the change; panels that cache text listen for
## NOTIFICATION_TRANSLATION_CHANGED.
static func set_pref(code: String) -> void:
	_pref = code
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("ui", "locale", code)
	cfg.save(PREFS_PATH)
	apply(resolve(code))


## What a choice means here: Auto picks the computer's language when a
## translation for it exists.
static func resolve(code: String) -> String:
	if not _forced.is_empty():
		return _forced
	if code.is_empty():
		return best_match(OS.get_locale(), available())
	return code if (code == SOURCE or has_file(code)) else SOURCE


## The best of `codes` for an OS locale such as "pt_PT", "zh_TW" or "es_MX".
static func best_match(os_locale: String, codes: Array) -> String:
	var loc := os_locale.replace("-", "_")
	if loc in codes:
		return loc
	var lang := loc.get_slice("_", 0).to_lower()
	var region := loc.get_slice("_", 1).to_upper() if loc.contains("_") else ""
	if lang == "zh":
		var trad := region in ["TW", "HK", "MO"] or loc.contains("Hant")
		var want := "zh_Hant" if trad else "zh_Hans"
		if want in codes:
			return want
	for c in codes:
		if String(c).get_slice("_", 0).to_lower() == lang:
			return String(c)
	return SOURCE


## Languages with a translation file, the source first. The pseudo-locales
## (tools/i18n/pseudo.py) are listed in debug builds only: they are for
## finding text that does not translate, not for players.
static func available() -> Array:
	var out := [SOURCE]
	var dev := OS.is_debug_build()
	for c in I18nLanguages.codes():
		if c == SOURCE or (I18nLanguages.is_pseudo(c) and not dev):
			continue
		if has_file(c):
			out.append(c)
	return out


static func has_file(code: String) -> bool:
	return FileAccess.file_exists("%s/%s.po" % [USER_DIR, code]) \
		or FileAccess.file_exists("%s/%s.po" % [RES_DIR, code]) \
		or ResourceLoader.exists("%s/%s.po" % [RES_DIR, code])


## Share of the game's text this language has (0..1), from
## locale/coverage.json (written by tools/i18n/check.py). -1 = unknown.
static func coverage(code: String) -> float:
	if code == SOURCE:
		return 1.0
	if not _coverage_read:
		_coverage_read = true
		if FileAccess.file_exists(COVERAGE_PATH):
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(COVERAGE_PATH))
			if d is Dictionary:
				_coverage = d
	return float(_coverage.get(code, -1.0))


## "Español · 62 %" for the picker.
static func label_for(code: String) -> String:
	var name := I18nLanguages.native_name(code)
	if code != SOURCE and name != I18nLanguages.english_name(code):
		name += " — " + I18nLanguages.english_name(code)
	var c := coverage(code)
	if code != SOURCE and c >= 0.0:
		name += " · %d %%" % int(round(c * 100.0))
	return name


## Load `code` (if needed) and make it the locale. Only the active language's
## translation stays on the server: Godot matches by language, so a loaded
## en_XA would otherwise still answer for "en".
static func apply(code: String) -> void:
	for c in _loaded.keys():
		if c != code:
			TranslationServer.remove_translation(_loaded[c])
			_loaded.erase(c)
	if code != SOURCE and not _loaded.has(code):
		var tr_res := _load_translation(code)
		if tr_res != null:
			TranslationServer.add_translation(tr_res)
			_loaded[code] = tr_res
		else:
			push_warning("I18n: no translation for '%s'; staying in English" % code)
			code = SOURCE
	_active = code
	TranslationServer.set_locale(code)


static func _load_translation(code: String) -> Translation:
	for p in ["%s/%s.po" % [USER_DIR, code], "%s/%s.po" % [RES_DIR, code]]:
		if FileAccess.file_exists(p) or ResourceLoader.exists(p):
			var r: Variant = load(p)
			if r is Translation:
				return r
	return null


## At boot (UiThemeBuilder.install): the saved choice, `--locale=xx` from the
## command line, and English for harness runs (their checks find buttons by
## their English text) unless one is given.
static func install() -> void:
	_forced = ""
	var harness := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--locale="):
			_forced = a.get_slice("=", 1)
		elif a.begins_with("--capture=") or a.begins_with("--run-script="):
			harness = true
	if _forced.is_empty() and harness:
		_forced = SOURCE
	apply(resolve(pref()))


## Selftests: forget the cached choice and loaded files.
static func reset_for_test() -> void:
	for code in _loaded:
		TranslationServer.remove_translation(_loaded[code])
	_loaded.clear()
	_pref = "<unread>"
	_forced = ""
	_active = SOURCE
	_coverage_read = false
	_coverage = {}
	TranslationServer.set_locale(SOURCE)

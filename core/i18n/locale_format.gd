class_name LocaleFormat
extends RefCounted

## Numbers the way the player's language writes them: decimal mark, digit
## grouping (including India's 3-2-2), percent placement. Values from CLDR
## (cldr-json numbers, "latn" numbering system); Phase 3 of
## plans/LOCALIZATION_PLAN.md replaces this table with a generated extract and
## adds month and day names.
##
## ONLY for text a person reads. Machine text (G-code, ESPHome YAML, CSV, save
## files, Home Assistant values) keeps String.num / "%" with a "." decimal
## point and must never come through here.
##
## Pure static. `code` defaults to the active locale (I18n.locale()).

const NBSP := "\u00a0"  # no-break space
const NNBSP := "\u202f"  # narrow no-break space (French grouping)

## code -> [decimal, group, grouping ("3" | "3,2"), percent pattern, min digits to group]
const RULES := {
	"en": [".", ",", "3", "{n}%", 4],
	"es": [",", ".", "3", "{n} %", 5],
	"fr": [",", NNBSP, "3", "{n}" + NNBSP + "%", 4],
	"de": [",", ".", "3", "{n}" + NBSP + "%", 4],
	"it": [",", ".", "3", "{n}%", 5],
	"pt_BR": [",", ".", "3", "{n}%", 4],
	"nl": [",", ".", "3", "{n}%", 4],
	"pl": [",", NBSP, "3", "{n}%", 5],
	"ru": [",", NBSP, "3", "{n}" + NBSP + "%", 4],
	"uk": [",", NBSP, "3", "{n}%", 4],
	"tr": [",", ".", "3", "%{n}", 4],
	"vi": [",", ".", "3", "{n}%", 4],
	"id": [",", ".", "3", "{n}%", 4],
	"ms": [".", ",", "3", "{n}%", 4],
	"tl": [".", ",", "3", "{n}%", 4],
	"sw": [".", ",", "3", "{n}%", 4],
	"hi": [".", ",", "3,2", "{n}%", 4],
	"mr": [".", ",", "3,2", "{n}%", 4],
	"bn": [".", ",", "3,2", "{n}%", 4],
	"gu": [".", ",", "3,2", "{n}%", 4],
	"pa": [".", ",", "3,2", "{n}%", 4],
	"te": [".", ",", "3,2", "{n}%", 4],
	"ta": [".", ",", "3,2", "{n}%", 4],
	"kn": [".", ",", "3,2", "{n}%", 4],
	"ur": [".", ",", "3", "{n}%", 4],
	"ar": [".", ",", "3", "{n}%", 4],
	"fa": ["/", ",", "3", "{n}%", 4],
	"zh_Hans": [".", ",", "3", "{n}%", 4],
	"zh_Hant": [".", ",", "3", "{n}%", 4],
	"yue": [".", ",", "3", "{n}%", 4],
	"ja": [".", ",", "3", "{n}%", 4],
	"ko": [".", ",", "3", "{n}%", 4],
	"th": [".", ",", "3", "{n}%", 4],
}


static func _rules(code: String) -> Array:
	var c := I18n.locale() if code.is_empty() else code
	if RULES.has(c):
		return RULES[c]
	var lang := c.get_slice("_", 0)
	return RULES.get(lang, RULES["en"])


## Digit grouping of a whole number: 1234567 -> "1,234,567" (en),
## "12,34,567" (hi), "1 234 567" (fr).
static func integer(n: int, code: String = "") -> String:
	var r := _rules(code)
	return ("-" if n < 0 else "") + _group(str(absi(n)), r)


## `places` decimals, trailing zeros dropped: 3.50 -> "3.5" (en), "3,5" (de).
static func decimal(x: float, places: int = 2, code: String = "") -> String:
	if is_nan(x) or is_inf(x):
		return "—"
	var r := _rules(code)
	var s := String.num(absf(x), places)
	var whole := s.get_slice(".", 0)
	var frac := s.get_slice(".", 1).rstrip("0") if s.contains(".") else ""
	var out := _group(whole, r)
	if not frac.is_empty():
		out += String(r[0]) + frac
	return ("-" if x < 0.0 and s.to_float() != 0.0 else "") + out


## A fixed number of decimals, zeros kept: readouts that must not jitter.
static func fixed(x: float, places: int, code: String = "") -> String:
	if is_nan(x) or is_inf(x):
		return "—"
	var r := _rules(code)
	var s := ("%." + str(places) + "f") % absf(x)
	var whole := s.get_slice(".", 0)
	var out := _group(whole, r)
	if places > 0:
		out += String(r[0]) + s.get_slice(".", 1)
	return ("-" if x < 0.0 and s.to_float() != 0.0 else "") + out


## 0.4231 -> "42%" (en), "42 %" (de), "%42" (tr).
static func percent(frac: float, places: int = 0, code: String = "") -> String:
	var r := _rules(code)
	return String(r[3]).format({"n": decimal(frac * 100.0, places, code)})


static func decimal_mark(code: String = "") -> String:
	return String(_rules(code)[0])


static func _group(digits: String, r: Array) -> String:
	if digits.length() < int(r[4]):
		return digits
	var sep := String(r[1])
	var out := ""
	var i := digits.length()
	var first := true
	var step := 3
	while i > step:
		out = sep + digits.substr(i - step, step) + out
		i -= step
		if first and String(r[2]) == "3,2":
			step = 2
		first = false
	return digits.substr(0, i) + out

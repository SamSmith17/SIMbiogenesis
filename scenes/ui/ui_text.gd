class_name UiText
extends RefCounted

## Player-facing text, written like a person would. Every count, quantity and
## duration on screen should come through here instead of a format string, so
## the game never says "1 days", "occupant(s)", "1473946.5" or "0.75000 m".
##
##   UiText.count(3, "occupant")      -> "3 occupants"
##   UiText.count(1, "person")        -> "1 person"   (irregular plurals known)
##   UiText.num(2843.0, "W")          -> "2.84 kW"    (SI prefix, 3 significant)
##   UiText.num(0.7512, "m")          -> "0.75 m"
##   UiText.thousands(1473946)        -> "1,473,946"
##   UiText.duration(0.5)             -> "30 min"     (hours in)
##   UiText.pct(0.4231)               -> "42%"
##   UiText.fit(font, text, px, w)    -> text ellipsized to w (canvas drawing)
##
## Pure static; tested by scenes/ui/ui_text_selftest.gd.

const IRREGULAR := {
	"person": "people", "child": "children", "man": "men", "woman": "women",
	"foot": "feet", "tooth": "teeth", "mouse": "mice", "goose": "geese",
	"cactus": "cacti", "fish": "fish", "sheep": "sheep", "series": "series",
}
## Units that take SI prefixes (k, M, G, and m below 1 only where it reads well).
const SI_UNITS := ["W", "Wh", "J", "V", "A", "Hz", "L", "g", "Pa"]
const ELLIPSIS := "…"


## Plural form of a single English noun.
static func plural_of(word: String) -> String:
	if word.is_empty():
		return word
	var low := word.to_lower()
	if IRREGULAR.has(low):
		var p: String = IRREGULAR[low]
		return p.capitalize() if word[0] == word[0].to_upper() and word[0] != word[0].to_lower() else p
	if low.ends_with("y") and low.length() > 1 and not "aeiou".contains(low[low.length() - 2]):
		return word.left(word.length() - 1) + "ies"
	if low.ends_with("s") or low.ends_with("x") or low.ends_with("z") or low.ends_with("ch") or low.ends_with("sh"):
		return word + "es"
	return word + "s"


## "1 day" / "3 days"; `plural_form` overrides the rule for odd nouns.
static func plural(n: float, word: String, plural_form: String = "") -> String:
	var one := absf(n - 1.0) < 1e-9
	return word if one else (plural_form if not plural_form.is_empty() else plural_of(word))


## "3 occupants", "1 person", "1,204 people".
static func count(n: float, word: String, plural_form: String = "") -> String:
	var num_s := thousands(int(round(n))) if absf(n - round(n)) < 1e-9 else _sig(n, 3)
	return "%s %s" % [num_s, plural(n, word, plural_form)]


## 1473946 -> "1,473,946".
static func thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var i := s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	out = s.substr(0, i) + out
	return ("-" if n < 0 else "") + out


## A quantity with its unit at a precision that suits its size: 3 significant
## figures, SI prefixes for SI units, never trailing ".000". NaN / INF read "—".
static func num(x: float, unit: String = "", sig: int = 3) -> String:
	if is_nan(x) or is_inf(x):
		return "—"
	var u := unit
	var v := x
	if unit in SI_UNITS:
		var ax := absf(x)
		if ax >= 1e9:
			v = x / 1e9
			u = "G" + unit
		elif ax >= 1e6:
			v = x / 1e6
			u = "M" + unit
		elif ax >= 1e4 or (ax >= 1e3 and unit != "L"):
			v = x / 1e3
			u = "k" + unit
	var s := _sig(v, sig)
	return s if u.is_empty() else "%s %s" % [s, u]


## `sig` significant figures, at most 2 decimals for small values, thousands
## separators for large ones.
static func _sig(v: float, sig: int) -> String:
	var av := absf(v)
	if av >= pow(10.0, sig - 1):
		return thousands(int(round(v)))
	if av < 1e-9:
		return "0"
	var decimals := clampi(sig - 1 - int(floor(log(av) / log(10.0))), 0, 2)
	var s := String.num(v, decimals)
	if decimals > 0 and s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


## Hours in, words out: "45 s", "30 min", "2.5 h", "3 days", "2 weeks".
static func duration(hours: float) -> String:
	if is_nan(hours) or is_inf(hours):
		return "—"
	var h := absf(hours)
	if h < 1.0 / 60.0:
		return "%d s" % int(round(h * 3600.0))
	if h < 1.0:
		return "%d min" % int(round(h * 60.0))
	if h < 48.0:
		return "%s h" % _sig(h, 2 if h < 10.0 else 3)
	var days := h / 24.0
	if days < 14.0:
		return count(round(days * 10.0) / 10.0 if days < 10.0 else round(days), "day")
	return count(round(days / 7.0), "week")


## 0.4231 -> "42%" (fraction in); `decimals` for small shares.
static func pct(fraction: float, decimals: int = 0) -> String:
	if is_nan(fraction):
		return "—"
	return "%s%%" % String.num(fraction * 100.0, decimals)


## First letter upper, the rest as written ("power scoreboard" -> "Power scoreboard").
static func sentence(s: String) -> String:
	if s.is_empty():
		return s
	return s[0].to_upper() + s.substr(1)


## A display name from an internal id: "siphon_hydro" -> "Siphon hydro".
static func from_id(id: String) -> String:
	return sentence(id.replace("_", " ").replace("-", " ").strip_edges())


## Canvas text fitted to `max_w` px with an ellipsis. Reports a truncation to
## the UI audit (where = a stable label for the drawing site).
static func fit(font: Font, text: String, font_size: int, max_w: float, where: String = "") -> String:
	if font == null or text.is_empty() or max_w <= 0.0:
		return text
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return text
	if not where.is_empty():
		UiAudit.note_canvas_truncation(where, text)
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		var cand := text.left(mid).strip_edges(false, true) + ELLIPSIS
		if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
			lo = mid
		else:
			hi = mid - 1
	return text.left(lo).strip_edges(false, true) + ELLIPSIS if lo > 0 else ELLIPSIS

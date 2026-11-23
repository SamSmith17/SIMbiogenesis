class_name I18nLanguages
extends RefCounted

## The languages the game knows about, in the order of the plan's tiers
## (plans/LOCALIZATION_PLAN.md): widest total readership (first + second
## language speakers) first. A language appears in the picker only once a
## translation file for it exists (I18n.available()).
##
## Each row: code (Godot / gettext locale), English name, native name, script
## (for font fallbacks), rtl, tier (0 = source, 1 = proof of concept, 2 = tier 1,
## 3 = tier 2, 4 = long tail, 9 = pseudo / developer), engine hint for
## tools/i18n/translate.py ("llm" | "mt").
##
## Pure data: tools/i18n/*.py read the same table from locale/languages.json,
## which tools/i18n/sync_languages.py writes from this file. Edit here.

const ROWS := [
	["en", "English", "English", "latin", false, 0, ""],
	# Proof of concept: one of each hard case.
	["es", "Spanish", "Español", "latin", false, 1, "llm"],
	["zh_Hans", "Chinese (Simplified)", "简体中文", "han", false, 1, "llm"],
	["ar", "Arabic", "العربية", "arabic", true, 1, "llm"],
	["hi", "Hindi", "हिन्दी", "devanagari", false, 1, "llm"],
	# Tier 1.
	["fr", "French", "Français", "latin", false, 2, "llm"],
	["pt_BR", "Portuguese (Brazil)", "Português (Brasil)", "latin", false, 2, "llm"],
	["ru", "Russian", "Русский", "cyrillic", false, 2, "llm"],
	["bn", "Bengali", "বাংলা", "bengali", false, 2, "llm"],
	["ur", "Urdu", "اردو", "arabic", true, 2, "llm"],
	["id", "Indonesian", "Bahasa Indonesia", "latin", false, 2, "llm"],
	["de", "German", "Deutsch", "latin", false, 2, "llm"],
	["ja", "Japanese", "日本語", "japanese", false, 2, "llm"],
	# Tier 2.
	["tr", "Turkish", "Türkçe", "latin", false, 3, "llm"],
	["vi", "Vietnamese", "Tiếng Việt", "latin", false, 3, "llm"],
	["ko", "Korean", "한국어", "hangul", false, 3, "llm"],
	["it", "Italian", "Italiano", "latin", false, 3, "llm"],
	["fa", "Persian", "فارسی", "arabic", true, 3, "llm"],
	["tl", "Filipino (Tagalog)", "Filipino", "latin", false, 3, "llm"],
	["sw", "Swahili", "Kiswahili", "latin", false, 3, "llm"],
	["th", "Thai", "ไทย", "thai", false, 3, "llm"],
	["mr", "Marathi", "मराठी", "devanagari", false, 3, "llm"],
	["te", "Telugu", "తెలుగు", "telugu", false, 3, "llm"],
	["ta", "Tamil", "தமிழ்", "tamil", false, 3, "llm"],
	["pa", "Punjabi", "ਪੰਜਾਬੀ", "gurmukhi", false, 3, "llm"],
	["pl", "Polish", "Polski", "latin", false, 3, "llm"],
	["uk", "Ukrainian", "Українська", "cyrillic", false, 3, "llm"],
	["ha", "Hausa", "Hausa", "latin", false, 3, "mt"],
	["zh_Hant", "Chinese (Traditional)", "繁體中文", "han_trad", false, 3, "llm"],
	["yue", "Cantonese", "粵語", "han_trad", false, 3, "llm"],
	["gu", "Gujarati", "ગુજરાતી", "gujarati", false, 3, "llm"],
	["kn", "Kannada", "ಕನ್ನಡ", "kannada", false, 3, "llm"],
	["am", "Amharic", "አማርኛ", "ethiopic", false, 3, "mt"],
	["yo", "Yoruba", "Yorùbá", "latin", false, 3, "mt"],
	["nl", "Dutch", "Nederlands", "latin", false, 3, "llm"],
	["ms", "Malay", "Bahasa Melayu", "latin", false, 3, "llm"],
	# Pseudo-locales for finding unwrapped text and overflow (tools/i18n/pseudo.py).
	["en_XA", "Pseudo (long accents)", "Ƥšéûđô", "latin", false, 9, ""],
	["ar_XB", "Pseudo (right to left)", "Pseudo RTL", "latin", true, 9, ""],
]


static func row(code: String) -> Array:
	for r in ROWS:
		if r[0] == code:
			return r
	return []


static func has(code: String) -> bool:
	return not row(code).is_empty()


static func native_name(code: String) -> String:
	var r := row(code)
	return String(r[2]) if not r.is_empty() else code


static func english_name(code: String) -> String:
	var r := row(code)
	return String(r[1]) if not r.is_empty() else code


static func script_of(code: String) -> String:
	var r := row(code)
	return String(r[3]) if not r.is_empty() else "latin"


static func is_rtl(code: String) -> bool:
	var r := row(code)
	return bool(r[4]) if not r.is_empty() else false


static func tier(code: String) -> int:
	var r := row(code)
	return int(r[5]) if not r.is_empty() else 4


static func is_pseudo(code: String) -> bool:
	return tier(code) == 9


## Every code, in tier order.
static func codes() -> Array:
	var out := []
	for r in ROWS:
		out.append(r[0])
	return out

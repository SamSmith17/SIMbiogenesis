class_name NpcDisplayPrefs
extends RefCounted

## Which body style NPCs are drawn with. A player choice, persisted globally
## rather than per map, because it is a taste about the game rather than a
## property of a site.
##
## The distinction that matters in the code: STYLE_SIMPLE means the player
## *chose* the stylised figure, which is different from the rigged body being
## unavailable. Both end up drawing the same figure, but only the first should
## survive installing the art, and only the second is worth reporting as a
## missing-asset condition.

const STYLE_HUMANOID := "humanoid"
const STYLE_SIMPLE := "simple"

const CFG_PATH := "user://npc_display.cfg"
const SECTION := "npc"

static var _style := ""


static func style() -> String:
	if _style.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_style = str(cfg.get_value(SECTION, "style", STYLE_HUMANOID))
		if _style != STYLE_SIMPLE:
			_style = STYLE_HUMANOID
	return _style


static func set_style(s: String) -> void:
	_style = STYLE_SIMPLE if s == STYLE_SIMPLE else STYLE_HUMANOID
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "style", _style)
	cfg.save(CFG_PATH)


## True when the player asked for the stylised body. Deliberately NOT the same
## question as "is the rigged body available" — see the class comment.
static func wants_simple() -> bool:
	return style() == STYLE_SIMPLE

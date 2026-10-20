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
## Tri-state: -1 means "not loaded yet", so a real `false` from disk is never
## confused with the unloaded default (mirrors the `_style.is_empty()` check
## above, just for a bool instead of a string).
static var _colors_on := -1
## Bumped by every setter here. These are statics with no signal to connect to,
## so anything caching a value derived from them (the agent-dot cache in
## NpcPopulationBridge) compares this instead — otherwise toggling the tint
## mid-session would keep serving stale colors until the next roster change.
static var _generation := 0


## Monotonic counter of display-pref changes. Cheap to poll; see _generation.
static func generation() -> int:
	return _generation


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
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "style", _style)
	cfg.save(CFG_PATH)


## True when the player asked for the stylised body. Deliberately NOT the same
## question as "is the rigged body available" — see the class comment.
static func wants_simple() -> bool:
	return style() == STYLE_SIMPLE


## Overhead readout (the morale bar + task tag above each head):
##   always — ambient within AMBIENT_STATUS_DIST_M, plus on aim (the default)
##   aim    — only for the person the crosshair is on
##   off    — never (the name on aim is unaffected; that is basic interaction)
const OVERHEAD_ALWAYS := "always"
const OVERHEAD_AIM := "aim"
const OVERHEAD_OFF := "off"
const OVERHEAD_MODES: Array = [OVERHEAD_ALWAYS, OVERHEAD_AIM, OVERHEAD_OFF]
static var _overhead := ""


static func overhead_mode() -> String:
	if _overhead.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_overhead = str(cfg.get_value(SECTION, "overhead", OVERHEAD_ALWAYS))
		if not OVERHEAD_MODES.has(_overhead):
			_overhead = OVERHEAD_ALWAYS
	return _overhead


static func set_overhead_mode(m: String) -> void:
	_overhead = m if OVERHEAD_MODES.has(m) else OVERHEAD_ALWAYS
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "overhead", _overhead)
	cfg.save(CFG_PATH)


## THE MASTER SWITCH (Settings → NPC → "Simulate & draw NPCs"). Off = no
## population at all: the graph view skips the population tick and the
## per-frame crowd slices, frees the avatar host and the crowd renderer, and
## hands every pop-driven habitat back to its classic constant-rate demand —
## for site analysis with none of the people's CPU/GPU cost. The roster is
## FROZEN, not erased (it rides each habitat's pop_state), so switching back on
## resumes it; a long gap takes the population's ordinary coarse catch-up.
## The gate lives in SystemGraphView, never in the bridge, so the challenge
## bake and the offline selftests (which drive the bridge directly) are
## untouched. Default on.
static var _npcs_on := -1
## Session-only override (never saved): festival mode and the --capture
## harnesses need people whatever the player's saved choice is.
static var _npcs_forced := false


static func npcs_enabled() -> bool:
	if _npcs_forced:
		return true
	if _npcs_on < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "npcs_enabled", true))
		_npcs_on = 1 if on else 0
	return _npcs_on == 1


## The SAVED choice (what the settings checkbox shows), ignoring the
## session override.
static func npcs_enabled_saved() -> bool:
	var forced := _npcs_forced
	_npcs_forced = false
	var on := npcs_enabled()
	_npcs_forced = forced
	return on


static func set_npcs_enabled(on: bool) -> void:
	_npcs_on = 1 if on else 0
	_generation += 1
	_save_key("npcs_enabled", on)


static func force_npcs_for_session(on: bool = true) -> void:
	if _npcs_forced != on:
		_npcs_forced = on
		_generation += 1


## Which people are DRAWN at festival scale (the sim runs regardless):
##   home — only the focused camp's people (the full-tier avatars)
##   all  — everyone, figures near and cards far (the default)
##   lod  — everyone within crowd_lod_m of the camera
##   none — nobody (dots and ledgers keep working)
const CROWD_HOME := "home"
const CROWD_ALL := "all"
const CROWD_LOD := "lod"
const CROWD_NONE := "none"
const CROWD_MODES: Array = [CROWD_HOME, CROWD_ALL, CROWD_LOD, CROWD_NONE]
const CROWD_LOD_DEFAULT_M := 400.0
static var _crowd := ""
static var _crowd_lod := -1.0


static func crowd_draw() -> String:
	if _crowd.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			_crowd = str(cfg.get_value(SECTION, "crowd_draw", CROWD_ALL))
		if not CROWD_MODES.has(_crowd):
			_crowd = CROWD_ALL
	return _crowd


static func set_crowd_draw(m: String) -> void:
	_crowd = m if CROWD_MODES.has(m) else CROWD_ALL
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "crowd_draw", _crowd)
	cfg.save(CFG_PATH)


static func crowd_lod_m() -> float:
	if _crowd_lod < 0.0:
		var cfg := ConfigFile.new()
		_crowd_lod = CROWD_LOD_DEFAULT_M
		if cfg.load(CFG_PATH) == OK:
			_crowd_lod = clampf(float(cfg.get_value(SECTION, "crowd_lod_m", CROWD_LOD_DEFAULT_M)), 50.0, 5000.0)
	return _crowd_lod


static func set_crowd_lod_m(m: float) -> void:
	_crowd_lod = clampf(m, 50.0, 5000.0)
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "crowd_lod_m", _crowd_lod)
	cfg.save(CFG_PATH)


## The morale BAR over people's heads. Off by default: the body glow (mood,
## and green FUCK YES! for a peak experience) carries the same reading.
static var _mood_bars := -1

static func mood_bars() -> bool:
	if _mood_bars < 0:
		var cfg := ConfigFile.new()
		var on := false
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "mood_bars", false))
		_mood_bars = 1 if on else 0
	return _mood_bars == 1


static func set_mood_bars(on: bool) -> void:
	_mood_bars = 1 if on else 0
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "mood_bars", on)
	cfg.save(CFG_PATH)


## The DISTANT CROWD: the light tier's far dots (CrowdRenderer cards). Off =
## no dots; the light tier is drawn only as figures inside the figure reach,
## dissolving out toward its edge. (It used to hide the light tier outright,
## and the overflow of the full tier with it: whole camps popped in and out
## as they switched simulation tier when the camera moved.) Full-tier people
## are always drawn. Default on. The key keeps its old name, light_crowd.
static var _light_crowd := -1

static func light_crowd() -> bool:
	if _light_crowd < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "light_crowd", true))
		_light_crowd = 1 if on else 0
	return _light_crowd == 1


static func set_light_crowd(on: bool) -> void:
	_light_crowd = 1 if on else 0
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "light_crowd", on)
	cfg.save(CFG_PATH)


## LOOK vs PERFORMANCE (Settings → NPCs → Crowd detail). Each is 0 = Auto
## (the graphics-quality default), else the player's number.
##   full_figures   — people drawn as full stick figures / rigged bodies
##                    (NpcPopulationHost's hero pool, ~0.1 ms each).
##   full_sim       — people the FULL engine simulates (CrowdFocus budget;
##                    only full-tier people can be full figures).
##   figure_dist_m  — how far the crowd's capsule figures reach before they
##                    become dots.
##   speed_shed     — shrink both budgets at 300×+ (a blur at that speed).
const FULL_FIGURES_MAX := 600
const FULL_SIM_MAX := 1000
const FIGURE_DIST_MAX := 1000.0
static var _full_figures := -1
static var _full_sim := -1
static var _figure_dist := -1.0
static var _speed_shed := -1


static func full_figures() -> int:
	if _full_figures < 0:
		_full_figures = clampi(int(_load_key("full_figures", 0)), 0, FULL_FIGURES_MAX)
	return _full_figures


static func set_full_figures(n: int) -> void:
	_full_figures = clampi(n, 0, FULL_FIGURES_MAX)
	_generation += 1
	_save_key("full_figures", _full_figures)


static func full_sim() -> int:
	if _full_sim < 0:
		_full_sim = clampi(int(_load_key("full_sim", 0)), 0, FULL_SIM_MAX)
	return _full_sim


static func set_full_sim(n: int) -> void:
	_full_sim = clampi(n, 0, FULL_SIM_MAX)
	_generation += 1
	_save_key("full_sim", _full_sim)


static func figure_dist_m() -> float:
	if _figure_dist < 0.0:
		_figure_dist = clampf(float(_load_key("figure_dist_m", 0.0)), 0.0, FIGURE_DIST_MAX)
	return _figure_dist


static func set_figure_dist_m(m: float) -> void:
	_figure_dist = clampf(m, 0.0, FIGURE_DIST_MAX)
	_generation += 1
	_save_key("figure_dist_m", _figure_dist)


static func speed_shed() -> bool:
	if _speed_shed < 0:
		_speed_shed = 1 if bool(_load_key("speed_shed", true)) else 0
	return _speed_shed == 1


static func set_speed_shed(on: bool) -> void:
	_speed_shed = 1 if on else 0
	_generation += 1
	_save_key("speed_shed", on)


static func _load_key(key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return default
	return cfg.get_value(SECTION, key, default)


## The FUN METER (scenes/ui/fun_meter.gd): on/off and where the player
## dragged it (Vector2(-1, -1) = its default corner).
static var _fun_meter := -1
static var _fun_pos := Vector2(-2.0, -2.0)

static func fun_meter() -> bool:
	if _fun_meter < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "fun_meter", true))
		_fun_meter = 1 if on else 0
	return _fun_meter == 1


static func set_fun_meter(on: bool) -> void:
	_fun_meter = 1 if on else 0
	_generation += 1
	_save_key("fun_meter", on)


static func fun_meter_pos() -> Vector2:
	if _fun_pos.x < -1.5:
		var cfg := ConfigFile.new()
		_fun_pos = Vector2(-1.0, -1.0)
		if cfg.load(CFG_PATH) == OK:
			var v: Variant = cfg.get_value(SECTION, "fun_meter_pos", Vector2(-1.0, -1.0))
			if v is Vector2:
				_fun_pos = v
	return _fun_pos


static func set_fun_meter_pos(p: Vector2) -> void:
	_fun_pos = p
	_save_key("fun_meter_pos", p)


## A beacon over each FUCK YES!!! the toast announces (PeakBeacon).
static var _beacons := -1

static func peak_beacons() -> bool:
	if _beacons < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "peak_beacons", true))
		_beacons = 1 if on else 0
	return _beacons == 1


static func set_peak_beacons(on: bool) -> void:
	_beacons = 1 if on else 0
	_save_key("peak_beacons", on)


static func _save_key(key: String, v: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, key, v)
	cfg.save(CFG_PATH)


## MO-CAP SPICE for the stick figure (NpcMocapSpice): how often a nearby
## stick figure breaks into a real motion-captured clip. 0 = never (pure
## procedural), 0.5 = the designed rate, 1 = twice as often.
static var _mocap_spice := -1.0

static func mocap_spice() -> float:
	if _mocap_spice < 0.0:
		var cfg := ConfigFile.new()
		var v := 0.5
		if cfg.load(CFG_PATH) == OK:
			v = float(cfg.get_value(SECTION, "mocap_spice", 0.5))
		_mocap_spice = clampf(v, 0.0, 1.0)
	return _mocap_spice


static func set_mocap_spice(v: float) -> void:
	_mocap_spice = clampf(v, 0.0, 1.0)
	_save_key("mocap_spice", _mocap_spice)


## Stage music volume, 0..1 (0 = off). A venue with a track (its `music`,
## a file in StageMusic.DIR) plays it while a set is on (StageMusic).
static var _stage_music := -1.0

static func stage_music_volume() -> float:
	if _stage_music < 0.0:
		var cfg := ConfigFile.new()
		var v := 0.8
		if cfg.load(CFG_PATH) == OK:
			v = float(cfg.get_value(SECTION, "stage_music_volume", 0.8))
		_stage_music = clampf(v, 0.0, 1.0)
	return _stage_music


static func set_stage_music_volume(v: float) -> void:
	_stage_music = clampf(v, 0.0, 1.0)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "stage_music_volume", _stage_music)
	cfg.save(CFG_PATH)


## The first-person ambient bed's volume, 0..1 (0 = off): wind, rain, the
## nearest stream, birdsong (AmbientBed). Beside the stage music in
## Settings → NPCs, and in this file because it is the game's one sound
## taste file.
static var _ambient := -1.0

static func ambient_volume() -> float:
	if _ambient < 0.0:
		var cfg := ConfigFile.new()
		var v := 0.7
		if cfg.load(CFG_PATH) == OK:
			v = float(cfg.get_value(SECTION, "ambient_volume", 0.7))
		_ambient = clampf(v, 0.0, 1.0)
	return _ambient


static func set_ambient_volume(v: float) -> void:
	_ambient = clampf(v, 0.0, 1.0)
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "ambient_volume", _ambient)
	cfg.save(CFG_PATH)


## The FUCK YES! toast (the Peak Experience score always counts).
static var _peak_toasts := -1

static func peak_toasts() -> bool:
	if _peak_toasts < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "peak_toasts", true))
		_peak_toasts = 1 if on else 0
	return _peak_toasts == 1


static func set_peak_toasts(on: bool) -> void:
	_peak_toasts = 1 if on else 0
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "peak_toasts", on)
	cfg.save(CFG_PATH)


## True when each person should render with their own distinct pastel tint
## (the default). False renders everyone in plain black — no way to tell
## individuals apart by color, only by name/nametag.
static func colors_enabled() -> bool:
	if _colors_on < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "colors_on", true))
		_colors_on = 1 if on else 0
	return _colors_on == 1


static func set_colors_enabled(on: bool) -> void:
	_colors_on = 1 if on else 0
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, "colors_on", on)
	cfg.save(CFG_PATH)


# --- Custom names ---------------------------------------------------------------
## Names the player ADDS to the people's name pool (Settings → NPC → Names) —
## friends, crew, whoever. NpcAgent.name_pool() appends them to its built-in
## pool, so they turn up among everyone else. Stored as one string array.
const CUSTOM_NAMES_MAX := 500
const CUSTOM_NAME_MAX_LEN := 24
static var _custom_names_loaded := false
static var _custom_names := PackedStringArray()


static func custom_names() -> PackedStringArray:
	if not _custom_names_loaded:
		_custom_names_loaded = true
		var cfg := ConfigFile.new()
		if cfg.load(CFG_PATH) == OK:
			var v: Variant = cfg.get_value(SECTION, "custom_names", PackedStringArray())
			if v is PackedStringArray or v is Array:
				_custom_names = parse_names(", ".join(PackedStringArray(v)))
	return _custom_names


## Replace the custom names (already parsed or not). Returns what was kept.
static func set_custom_names(names: PackedStringArray) -> PackedStringArray:
	_custom_names_loaded = true
	_custom_names = parse_names(", ".join(names))
	_generation += 1
	_save_key("custom_names", _custom_names)
	return _custom_names


## "Alex, Sam ,  sam,Jo\nRiver" -> ["Alex", "Sam", "Jo", "River"]: split on
## commas, semicolons and new lines, trimmed, empty and duplicate (case-
## insensitive) entries dropped, each capped to CUSTOM_NAME_MAX_LEN, at most
## CUSTOM_NAMES_MAX. Pure — the settings field and the selftest share it.
static func parse_names(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {}
	var norm := text.replace(";", ",").replace("\n", ",").replace("\r", ",").replace("\t", " ")
	for part in norm.split(",", false):
		var n := part.strip_edges()
		while n.contains("  "):
			n = n.replace("  ", " ")
		if n.is_empty():
			continue
		n = n.substr(0, CUSTOM_NAME_MAX_LEN).strip_edges()
		var key := n.to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		out.append(n)
		if out.size() >= CUSTOM_NAMES_MAX:
			break
	return out


## Selftests: forget custom names in memory (writes nothing).
static func reset_custom_names_for_test(names: PackedStringArray = PackedStringArray()) -> void:
	_custom_names_loaded = true
	_custom_names = parse_names(", ".join(names))
	_generation += 1


# --- Dance to the beat ---------------------------------------------------------
## People dancing near a playing stage move on its beat and react to its drops
## (StageBeat). Off = the old free-running dance clock. Lights have their own
## per-light "Sound reactive" switch and do not read this.
static var _beat_sync := -1


static func beat_sync() -> bool:
	if _beat_sync < 0:
		var cfg := ConfigFile.new()
		var on := true
		if cfg.load(CFG_PATH) == OK:
			on = bool(cfg.get_value(SECTION, "beat_sync", true))
		_beat_sync = 1 if on else 0
	return _beat_sync == 1


static func set_beat_sync(on: bool) -> void:
	_beat_sync = 1 if on else 0
	_generation += 1
	_save_key("beat_sync", on)

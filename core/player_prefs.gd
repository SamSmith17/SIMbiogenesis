class_name PlayerPrefs
extends RefCounted

## The player's own body and camera — Settings → Player.
##
## Global (user://player.cfg), not per save: how you like to see yourself is a
## taste about the game, like NpcDisplayPrefs. The FOV is NOT here — it stays
## in sim_settings.cfg [camera] where SimSettingsController has always kept it
## (the Player tab just hosts its slider now).
##
## Same pattern as NpcDisplayPrefs: lazily-loaded static cache, a setter that
## writes through, and a `generation()` counter the player polls to apply a
## change live without signals (the settings panel and the player never hold
## references to each other).

const CFG_PATH := "user://player.cfg"
const SECTION := "player"

const CAMERA_FIRST := "first"
const CAMERA_THIRD := "third"

## Body choices. A custom body is "custom:<file name>" in CUSTOM_DIR.
## The default is the SILHOUETTE: the same stick figure the NPCs are drawn
## with (NpcSimpleFigure, black body, rim in the player's colour), so the
## player and the people around them read as one cast. FIGURE is its
## detailed variant (waist, hands, feet, head-look).
const BODY_SILHOUETTE := "silhouette"
const BODY_FIGURE := "figure"
const BODY_REMY := "remy"
const CUSTOM_PREFIX := "custom:"
const CUSTOM_DIR := "user://player_characters/"
const CUSTOM_EXTS: Array = ["glb", "gltf", "fbx"]

## Remy (the Mixamo body that ships in the gitignored asset pack).
const REMY_PATH := "res://Player Character/Walking (in place).fbx"

const TP_DISTANCE_MIN := 1.5
const TP_DISTANCE_MAX := 9.0

static var _loaded := false
static var _generation := 0
static var _camera := CAMERA_FIRST
static var _tp_distance := 3.4
static var _tp_shoulder := 1          ## -1 left, 0 centred, 1 right
static var _tp_recenter := true       ## driving: swing back behind the vehicle
static var _body := BODY_SILHOUETTE
static var _tint := Color(0.55, 0.62, 0.78)


static func generation() -> int:
	_ensure()
	return _generation


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	var cam := str(cfg.get_value(SECTION, "camera", CAMERA_FIRST))
	_camera = cam if cam == CAMERA_THIRD else CAMERA_FIRST
	_tp_distance = clampf(float(cfg.get_value(SECTION, "tp_distance", 3.4)), TP_DISTANCE_MIN, TP_DISTANCE_MAX)
	_tp_shoulder = clampi(int(cfg.get_value(SECTION, "tp_shoulder", 1)), -1, 1)
	_tp_recenter = bool(cfg.get_value(SECTION, "tp_recenter", true))
	_body = str(cfg.get_value(SECTION, "body", BODY_SILHOUETTE))
	var t: Variant = cfg.get_value(SECTION, "tint", _tint)
	if t is Color:
		_tint = t


static func _save_key(key: String, v: Variant) -> void:
	_generation += 1
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value(SECTION, key, v)
	cfg.save(CFG_PATH)


## Forget the cache and re-read the file on next use (a harness that
## byte-restored player.cfg).
static func reload_from_disk() -> void:
	reset_defaults()
	_loaded = false


## Back to defaults in memory (selftests); writes nothing.
static func reset_defaults() -> void:
	_loaded = true
	_camera = CAMERA_FIRST
	_tp_distance = 3.4
	_tp_shoulder = 1
	_tp_recenter = true
	_body = BODY_SILHOUETTE
	_tint = Color(0.55, 0.62, 0.78)
	_generation += 1


static func camera_mode() -> String:
	_ensure()
	return _camera


static func third_person() -> bool:
	return camera_mode() == CAMERA_THIRD


static func set_camera_mode(mode: String) -> void:
	_ensure()
	_camera = CAMERA_THIRD if mode == CAMERA_THIRD else CAMERA_FIRST
	_save_key("camera", _camera)


static func tp_distance() -> float:
	_ensure()
	return _tp_distance


static func set_tp_distance(m: float) -> void:
	_ensure()
	_tp_distance = clampf(m, TP_DISTANCE_MIN, TP_DISTANCE_MAX)
	_save_key("tp_distance", _tp_distance)


static func tp_shoulder() -> int:
	_ensure()
	return _tp_shoulder


static func set_tp_shoulder(side: int) -> void:
	_ensure()
	_tp_shoulder = clampi(side, -1, 1)
	_save_key("tp_shoulder", _tp_shoulder)


static func tp_recenter() -> bool:
	_ensure()
	return _tp_recenter


static func set_tp_recenter(on: bool) -> void:
	_ensure()
	_tp_recenter = on
	_save_key("tp_recenter", on)


static func body() -> String:
	_ensure()
	return _body


static func set_body(id: String) -> void:
	_ensure()
	_body = id if not id.is_empty() else BODY_SILHOUETTE
	_save_key("body", _body)


static func tint() -> Color:
	_ensure()
	return _tint


static func set_tint(c: Color) -> void:
	_ensure()
	_tint = c
	_save_key("tint", c)


static func remy_available() -> bool:
	return ResourceLoader.exists(REMY_PATH)


## Character files the player dropped into CUSTOM_DIR (file names, sorted).
static func custom_files() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(CUSTOM_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if CUSTOM_EXTS.has(f.get_extension().to_lower()):
			out.append(f)
	out.sort()
	return out


## The body choices to offer: [{id, label}], the silhouette first.
static func body_options() -> Array:
	var out: Array = [{"id": BODY_SILHOUETTE, "label": "Silhouette, like the NPCs (default)"},
		{"id": BODY_FIGURE, "label": "Detailed figure"}]
	if remy_available():
		out.append({"id": BODY_REMY, "label": "Remy (Mixamo)"})
	for f in custom_files():
		out.append({"id": CUSTOM_PREFIX + f, "label": "Custom: %s" % f.get_basename()})
	return out


static func ensure_custom_dir() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CUSTOM_DIR))
	return ProjectSettings.globalize_path(CUSTOM_DIR)

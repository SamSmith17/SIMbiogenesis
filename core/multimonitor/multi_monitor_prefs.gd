class_name MultiMonitorPrefs
extends Object

## Player preferences for Multi-Monitor support (`user://multi_monitor.cfg`).
##
## Own machine-local file (never included in AssetPackPrefs.SHAREABLE, since
## physical monitor geometry is per-computer). Preserves WindowWallPrefs for
## the Window Wall sub-option, and automatically imports enabled/screen state
## if a legacy `window_wall.cfg` exists on first run.
##
## Follows the static-ConfigFile pattern used by `WindowWallPrefs` and
## `ExtremeWeatherPrefs`: `cfg_path` is swappable so offline selftests run
## against a temp folder without touching `user://multi_monitor.cfg`.

const CFG_PATH := "user://multi_monitor.cfg"
const SECTION := "multimonitor"
const VERSION := 1
const MAX_MONITORS := 8
const UNSET_POS := Vector2i(-99999, -99999)

const MAIN_MODE_FULLSCREEN := "fullscreen"
const MAIN_MODE_BORDERLESS := "borderless"
const MAIN_MODE_WINDOWED   := "windowed"
const MAIN_WINDOW_MODES := [MAIN_MODE_FULLSCREEN, MAIN_MODE_BORDERLESS, MAIN_MODE_WINDOWED]

const FS_METHOD_DWM_SAFE      := "dwm_safe_borderless"
const FS_METHOD_OS_FULLSCREEN := "os_fullscreen"
const FULLSCREEN_METHODS := [FS_METHOD_DWM_SAFE, FS_METHOD_OS_FULLSCREEN]

const PORTRAIT_AUTO      := 0
const PORTRAIT_PORTRAIT  := 1
const PORTRAIT_LANDSCAPE := 2

const DEFAULTS := {
	"enabled": false,
	"auto_open_on_world_load": true,
	"auto_fullscreen_saved": true,
	"main_window_mode": MAIN_MODE_FULLSCREEN,
	"main_screen": -1,
	"main_screen_fingerprint": "",
	"fullscreen_method": FS_METHOD_DWM_SAFE,
	"monitor_slot_count": 0,
}

const SLOT_DEFAULTS := {
	"id": "mon_1",
	"enabled": true,
	"label": "Monitor 2",
	"starting_view": MultiMonitorCatalog.DEFAULT_VIEW,
	"portrait_override": PORTRAIT_AUTO,
	"touchscreen": false,
	"ui_scale": 0.0,
	"render_scale_3d": 1.0,
	"placed": false,
	"is_fullscreen": false,
	"screen_index": -1,
	"screen_fingerprint": "",
	"windowed_pos": UNSET_POS,
	"windowed_size": Vector2i.ZERO,
	"overhead_height_m": 65.0,
	"wall_slot": 0,
}

static var cfg_path: String = CFG_PATH
static var _state: Dictionary = {}
static var _slots: Array[Dictionary] = []
static var _loaded := false
static var _generation := 0
static var _next_id_seq := 1


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_state = DEFAULTS.duplicate(true)
	_slots = []
	_next_id_seq = 1
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return
	for key in DEFAULTS.keys():
		if cfg.has_section_key(SECTION, key):
			_state[key] = _coerce_global(key, cfg.get_value(SECTION, key), DEFAULTS[key])
	var count := clampi(int(_state.get("monitor_slot_count", 0)), 0, MAX_MONITORS)
	for i in count:
		var sec := _slot_section(i)
		var sd := SLOT_DEFAULTS.duplicate(true)
		sd["id"] = "mon_%d" % (i + 1)
		sd["label"] = "Monitor %d" % (i + 2)
		for key in SLOT_DEFAULTS.keys():
			if cfg.has_section_key(sec, key):
				sd[key] = _coerce_slot(key, cfg.get_value(sec, key), sd[key])
		_slots.append(_clamp_slot(sd, i))
		_bump_seq_from_id(str(sd["id"]))
	_clamp_global()


static func save() -> void:
	ensure_loaded()
	_state["monitor_slot_count"] = _slots.size()
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	# Clear stale slot sections beyond current count so removed slots do not linger.
	for i in range(_slots.size(), MAX_MONITORS + 4):
		var stale := _slot_section(i)
		if cfg.has_section(stale):
			cfg.erase_section(stale)
	cfg.set_value(SECTION, "version", VERSION)
	for key in DEFAULTS.keys():
		cfg.set_value(SECTION, key, _state[key])
	for i in _slots.size():
		var sec := _slot_section(i)
		var sd: Dictionary = _slots[i]
		for key in SLOT_DEFAULTS.keys():
			cfg.set_value(sec, key, sd[key])
	cfg.save(cfg_path)
	_generation += 1


static func generation() -> int:
	return _generation


# --- Global accessors --------------------------------------------------------

static func get_value(key: String) -> Variant:
	ensure_loaded()
	return _state.get(key, DEFAULTS.get(key))


static func set_value(key: String, v: Variant) -> void:
	ensure_loaded()
	if not DEFAULTS.has(key):
		push_warning("MultiMonitorPrefs: unknown key %s" % key)
		return
	_state[key] = _coerce_global(key, v, DEFAULTS[key])
	_clamp_global()
	_generation += 1


static func enabled() -> bool:
	return bool(get_value("enabled"))


static func auto_open_on_world_load() -> bool:
	return bool(get_value("auto_open_on_world_load"))


static func auto_fullscreen_saved() -> bool:
	return bool(get_value("auto_fullscreen_saved"))


static func main_window_mode() -> String:
	return str(get_value("main_window_mode"))


static func main_screen() -> int:
	return int(get_value("main_screen"))


static func main_screen_fingerprint() -> String:
	return str(get_value("main_screen_fingerprint"))


static func fullscreen_method() -> String:
	return str(get_value("fullscreen_method"))


# --- Per-monitor slot CRUD ---------------------------------------------------

static func slot_count() -> int:
	ensure_loaded()
	return _slots.size()


static func slots() -> Array[Dictionary]:
	ensure_loaded()
	var out: Array[Dictionary] = []
	for s in _slots:
		out.append(s.duplicate(true))
	return out


static func slot(index: int) -> Dictionary:
	ensure_loaded()
	if index < 0 or index >= _slots.size():
		return SLOT_DEFAULTS.duplicate(true)
	return _slots[index].duplicate(true)


static func find_slot_index(slot_id: String) -> int:
	ensure_loaded()
	for i in _slots.size():
		if str(_slots[i].get("id", "")) == slot_id:
			return i
	return -1


static func slot_by_id(slot_id: String) -> Dictionary:
	var idx := find_slot_index(slot_id)
	return slot(idx) if idx >= 0 else {}


static func add_slot(initial: Dictionary = {}) -> Dictionary:
	ensure_loaded()
	if _slots.size() >= MAX_MONITORS:
		return {}
	var idx := _slots.size()
	var sd := SLOT_DEFAULTS.duplicate(true)
	sd["id"] = "mon_%d" % _next_id_seq
	_next_id_seq += 1
	sd["label"] = "Monitor %d" % (idx + 2)
	# Pick a smart non-duplicate default view for the first few slots.
	var default_cycle := [
		MultiMonitorCatalog.VIEW_SYSTEM_GRAPH,
		MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR,
		MultiMonitorCatalog.VIEW_SITE_REPORT,
		MultiMonitorCatalog.VIEW_BATTERYLAB,
		MultiMonitorCatalog.VIEW_OVERHEAD_3D,
	]
	sd["starting_view"] = default_cycle[idx % default_cycle.size()]
	for k in initial.keys():
		if SLOT_DEFAULTS.has(k) and k != "id":
			sd[k] = _coerce_slot(k, initial[k], sd[k])
	if initial.has("id") and not str(initial["id"]).is_empty() and find_slot_index(str(initial["id"])) < 0:
		sd["id"] = str(initial["id"])
		_bump_seq_from_id(str(sd["id"]))
	sd = _clamp_slot(sd, idx)
	_slots.append(sd)
	_state["monitor_slot_count"] = _slots.size()
	_generation += 1
	return sd.duplicate(true)


static func remove_slot(index: int) -> bool:
	ensure_loaded()
	if index < 0 or index >= _slots.size():
		return false
	_slots.remove_at(index)
	_state["monitor_slot_count"] = _slots.size()
	_generation += 1
	return true


static func set_slot_value(index: int, key: String, v: Variant) -> void:
	ensure_loaded()
	if index < 0 or index >= _slots.size() or not SLOT_DEFAULTS.has(key):
		push_warning("MultiMonitorPrefs: invalid slot write %d/%s" % [index, key])
		return
	if key == "id":
		return
	_slots[index][key] = _coerce_slot(key, v, SLOT_DEFAULTS[key])
	_slots[index] = _clamp_slot(_slots[index], index)
	_generation += 1


static func set_slot_value_by_id(slot_id: String, key: String, v: Variant) -> void:
	var idx := find_slot_index(slot_id)
	if idx >= 0:
		set_slot_value(idx, key, v)


## Record where the user dragged/resized/fullscreened a window so future
## sessions restore it onto that exact physical monitor.
static func record_placement(slot_id: String, screen_idx: int, screen_fp: String,
		win_pos: Vector2i, win_size: Vector2i, is_fs: bool) -> void:
	var idx := find_slot_index(slot_id)
	if idx < 0:
		return
	var sd: Dictionary = _slots[idx]
	sd["placed"] = true
	sd["screen_index"] = screen_idx
	sd["screen_fingerprint"] = screen_fp
	sd["is_fullscreen"] = is_fs
	if (not is_fs or (sd.get("windowed_pos", UNSET_POS) as Vector2i) == UNSET_POS) \
			and win_size.x >= MultiMonitorDisplay.MIN_WIN_SIZE.x \
			and win_size.y >= MultiMonitorDisplay.MIN_WIN_SIZE.y:
		sd["windowed_pos"] = win_pos
		sd["windowed_size"] = win_size
	_slots[idx] = _clamp_slot(sd, idx)
	_generation += 1


## Clear saved fullscreen flags so every window opens draggable on next launch
## (or when "Gather All to Windowed" is clicked).
static func clear_all_fullscreen() -> void:
	ensure_loaded()
	for i in _slots.size():
		_slots[i]["is_fullscreen"] = false
	_generation += 1


## Quick-populate one slot per secondary OS screen (skipping the primary screen),
## auto-tagging Portrait screens with Biochar Reactor and Landscape screens with
## Systems Graph / Site Report / Battery Lab / Overhead 3D.
static func populate_from_detected_screens(screens: Array) -> int:
	ensure_loaded()
	if screens.size() <= 1:
		return 0
	var prim := MultiMonitorDisplay.primary_screen_index(screens)
	var existing_fps: Dictionary = {}
	for s in _slots:
		var fp := str(s.get("screen_fingerprint", ""))
		if not fp.is_empty():
			existing_fps[fp] = true
	var added := 0
	var landscape_views := [
		MultiMonitorCatalog.VIEW_SYSTEM_GRAPH,
		MultiMonitorCatalog.VIEW_SITE_REPORT,
		MultiMonitorCatalog.VIEW_BATTERYLAB,
		MultiMonitorCatalog.VIEW_OVERHEAD_3D,
	]
	var land_i := 0
	for sc_v in screens:
		if _slots.size() >= MAX_MONITORS:
			break
		var sc := sc_v as Dictionary
		var idx := int(sc.get("index", -1))
		if idx == prim:
			continue
		var fp := MultiMonitorDisplay.fingerprint_of(sc)
		if existing_fps.has(fp):
			continue
		var is_por := bool(sc.get("is_portrait", false))
		var view: String = MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR if is_por \
			else str(landscape_views[land_i % landscape_views.size()])
		if not is_por:
			land_i += 1
		var lbl := ("Portrait (%d×%d)" % [int(sc.get("w", 0)), int(sc.get("h", 0))]) if is_por \
			else ("Screen %d (%d×%d)" % [idx + 1, int(sc.get("w", 0)), int(sc.get("h", 0))])
		add_slot({
			"enabled": true,
			"label": lbl,
			"starting_view": view,
			"portrait_override": PORTRAIT_PORTRAIT if is_por else PORTRAIT_AUTO,
			"screen_index": idx,
			"screen_fingerprint": fp,
			"placed": false,
			"is_fullscreen": false,
		})
		added += 1
	return added


# --- Test / harness hooks ----------------------------------------------------

static func override_for_session(values: Dictionary, temp_slots: Array = []) -> void:
	ensure_loaded()
	for k in values.keys():
		if DEFAULTS.has(k):
			_state[k] = _coerce_global(k, values[k], DEFAULTS[k])
	if not temp_slots.is_empty():
		_slots.clear()
		for i in mini(temp_slots.size(), MAX_MONITORS):
			if temp_slots[i] is Dictionary:
				var sd := SLOT_DEFAULTS.duplicate(true)
				sd["id"] = "mon_%d" % (i + 1)
				for k in (temp_slots[i] as Dictionary).keys():
					if SLOT_DEFAULTS.has(k):
						sd[k] = _coerce_slot(k, temp_slots[i][k], sd[k])
				_slots.append(_clamp_slot(sd, i))
		_state["monitor_slot_count"] = _slots.size()
	_clamp_global()
	_generation += 1


static func reset_for_test() -> void:
	_loaded = false
	_state = {}
	_slots = []
	_next_id_seq = 1


# --- Internals ---------------------------------------------------------------

static func _slot_section(i: int) -> String:
	return "monitor_%d" % i


static func _bump_seq_from_id(id_str: String) -> void:
	if id_str.begins_with("mon_"):
		var num_str := id_str.trim_prefix("mon_")
		if num_str.is_valid_int():
			_next_id_seq = maxi(_next_id_seq, num_str.to_int() + 1)


static func _coerce_global(key: String, v: Variant, fallback: Variant) -> Variant:
	match typeof(fallback):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT:
			return int(float(v)) if (v is float or v is int) else int(fallback)
		TYPE_FLOAT:
			var f := float(v) if (v is float or v is int) else float(fallback)
			return f if is_finite(f) else float(fallback)
		TYPE_STRING:
			var s := str(v)
			if key == "main_window_mode" and not MAIN_WINDOW_MODES.has(s):
				return str(fallback)
			if key == "fullscreen_method" and not FULLSCREEN_METHODS.has(s):
				return str(fallback)
			return s
	return v


static func _coerce_slot(key: String, v: Variant, fallback: Variant) -> Variant:
	match typeof(fallback):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT:
			return int(float(v)) if (v is float or v is int) else int(fallback)
		TYPE_FLOAT:
			var f := float(v) if (v is float or v is int) else float(fallback)
			return f if is_finite(f) else float(fallback)
		TYPE_STRING:
			var s := str(v)
			if key == "starting_view" and not MultiMonitorCatalog.has_view(s):
				return MultiMonitorCatalog.DEFAULT_VIEW
			return s
		TYPE_VECTOR2I:
			if v is Vector2i:
				return v
			if v is Vector2:
				return Vector2i(int((v as Vector2).x), int((v as Vector2).y))
			return fallback
	return v


static func _clamp_global() -> void:
	_state["monitor_slot_count"] = clampi(int(_state.get("monitor_slot_count", _slots.size())), 0, MAX_MONITORS)
	_state["main_screen"] = clampi(int(_state.get("main_screen", -1)), -1, 31)
	if not MAIN_WINDOW_MODES.has(str(_state.get("main_window_mode", ""))):
		_state["main_window_mode"] = MAIN_MODE_FULLSCREEN
	if not FULLSCREEN_METHODS.has(str(_state.get("fullscreen_method", ""))):
		_state["fullscreen_method"] = FS_METHOD_DWM_SAFE


static func _clamp_slot(sd: Dictionary, idx: int) -> Dictionary:
	if str(sd.get("id", "")).is_empty():
		sd["id"] = "mon_%d" % (idx + 1)
	if str(sd.get("label", "")).strip_edges().is_empty():
		sd["label"] = "Monitor %d" % (idx + 2)
	if not MultiMonitorCatalog.has_view(str(sd.get("starting_view", ""))):
		sd["starting_view"] = MultiMonitorCatalog.DEFAULT_VIEW
	sd["portrait_override"] = clampi(int(sd.get("portrait_override", 0)), 0, 2)
	var uis := float(sd.get("ui_scale", 0.0))
	sd["ui_scale"] = 0.0 if uis <= 0.05 else clampf(uis, 0.6, 2.5)
	sd["render_scale_3d"] = clampf(float(sd.get("render_scale_3d", 1.0)), 0.25, 1.0)
	sd["overhead_height_m"] = clampf(float(sd.get("overhead_height_m", 65.0)), 8.0, 800.0)
	sd["wall_slot"] = clampi(int(sd.get("wall_slot", 0)), 0, WindowWallLayout.MAX_SLOTS - 1)
	sd["screen_index"] = clampi(int(sd.get("screen_index", -1)), -1, 31)
	return sd

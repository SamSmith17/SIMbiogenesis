class_name ConduitStylePresets
extends RefCounted

## Per-type style defaults + named library presets for 3D conduit look.
## Stored at user://conduit_style_presets.json (never committed).

const PATH := "user://conduit_style_presets.json"
const VERSION := 1

## Keys merged into ConduitKinds.type_meta for rendering.
const STYLE_KEYS := [
	"radius_m", "color", "roughness", "metallic", "flexible", "sag_amount",
	"ground_drape", "emissive", "emission_energy",
	"fitting_color", "plug_emissive", "jacket_emissive", "use_flow_shader",
	"flow_color", "flow_strength_default", "route_mode", "elbow_radius_frac",
	"end_slack_m", "pipe_size_in", "fitting_step_deg",
]

static var _cache: Dictionary = {}
static var _loaded := false


static func reload() -> void:
	_loaded = false
	_ensure()


## Headless selftests: ignore user:// type defaults so builtin kinds stay pure.
static func clear_memory_for_tests() -> void:
	_loaded = true
	_cache = {"version": VERSION, "type_defaults": {}, "named": []}


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_cache = {"version": VERSION, "type_defaults": {}, "named": []}
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_cache = parsed as Dictionary
		if not _cache.has("type_defaults"):
			_cache["type_defaults"] = {}
		if not _cache.has("named"):
			_cache["named"] = []


static func save() -> bool:
	_ensure()
	_cache["version"] = VERSION
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://"))
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(_cache, "\t"))
	f.close()
	return true


static func type_defaults(type_id: String) -> Dictionary:
	_ensure()
	var td: Dictionary = _cache.get("type_defaults", {}) as Dictionary
	var raw: Variant = td.get(type_id, {})
	if raw is Dictionary:
		return _deserialize_style(raw as Dictionary)
	return {}


static func set_type_defaults(type_id: String, style: Dictionary) -> bool:
	_ensure()
	if type_id.is_empty():
		return false
	var td: Dictionary = (_cache.get("type_defaults", {}) as Dictionary).duplicate(true)
	td[type_id] = _serialize_style(style)
	_cache["type_defaults"] = td
	return save()


static func list_named() -> Array:
	_ensure()
	var out: Array = []
	for p: Variant in _cache.get("named", []) as Array:
		if p is Dictionary:
			out.append((p as Dictionary).duplicate(true))
	return out


static func save_named(label: String, base_type: String, style: Dictionary) -> String:
	_ensure()
	var id := "style_%d" % Time.get_ticks_usec()
	var entry := {
		"id": id,
		"label": label if not label.is_empty() else base_type.capitalize(),
		"base_type": base_type,
		"style": _serialize_style(style),
	}
	var named: Array = (_cache.get("named", []) as Array).duplicate(true)
	named.append(entry)
	_cache["named"] = named
	save()
	return id


static func delete_named(preset_id: String) -> bool:
	_ensure()
	var named: Array = []
	var found := false
	for p: Variant in _cache.get("named", []) as Array:
		if p is Dictionary and str((p as Dictionary).get("id", "")) == preset_id:
			found = true
			continue
		named.append(p)
	if not found:
		return false
	_cache["named"] = named
	return save()


static func named_by_id(preset_id: String) -> Dictionary:
	for p: Variant in list_named():
		if str((p as Dictionary).get("id", "")) == preset_id:
			var d: Dictionary = (p as Dictionary).duplicate(true)
			d["style"] = _deserialize_style(d.get("style", {}) as Dictionary)
			return d
	return {}


static func style_dict_from_raw(raw: Dictionary) -> Dictionary:
	return _deserialize_style(raw)


static func style_to_raw(style: Dictionary) -> Dictionary:
	return _serialize_style(style)


## Merge saved type defaults into a kind meta dict (in-place).
static func apply_defaults_to_meta(type_id: String, meta: Dictionary) -> void:
	var d := type_defaults(type_id)
	if d.is_empty():
		return
	for k: String in STYLE_KEYS:
		if d.has(k):
			meta[k] = d[k]


static func style_from_connection(conn: Dictionary, type_id: String) -> Dictionary:
	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	var style: Dictionary = {}
	for k: String in STYLE_KEYS:
		if meta.has(k):
			style[k] = meta[k]
	# Per-connection overrides (optional). Deserialize Color arrays from JSON.
	var ov_raw: Dictionary = conn.get("conduit_style", {}) as Dictionary
	var ov := style_dict_from_raw(ov_raw) if not ov_raw.is_empty() else {}
	for k: String in ov.keys():
		style[k] = ov[k]
	return style


static func _serialize_style(style: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in style.keys():
		var ks := str(k)
		var v: Variant = style[k]
		if v is Color:
			var c: Color = v as Color
			out[ks] = [c.r, c.g, c.b, c.a]
		else:
			out[ks] = v
	return out


static func _deserialize_style(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in raw.keys():
		var ks := str(k)
		var v: Variant = raw[k]
		if v is Array and (v as Array).size() >= 3 \
				and (ks.contains("color") or ks.ends_with("_color")):
			var a: Array = v as Array
			out[ks] = Color(float(a[0]), float(a[1]), float(a[2]),
				float(a[3]) if a.size() > 3 else 1.0)
		else:
			out[ks] = v
	# Legacy metro → pipes.
	if out.has("route_mode"):
		out["route_mode"] = ConduitKinds.normalize_route_mode(str(out["route_mode"]))
	elif bool(out.get("metro_ground", false)):
		out["route_mode"] = "pipes"
	out.erase("metro_ground")
	return out

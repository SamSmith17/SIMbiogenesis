class_name AssetPackPrefs
extends RefCounted

## Preferences in an asset pack, and every other .cfg that travels.
##
## A .cfg is parsed by Godot's Variant parser, which understands more than
## plain values (resource references among them), so a .cfg from someone
## else's machine is never read as one. On export ConfigFile → a JSON
## document of PRIMITIVE values only ({"section": {"key": value}}); on import
## that JSON is decoded with the same type whitelist and written back through
## ConfigFile.set_value. Anything else (objects, resources, callables, …) is
## dropped on the way out AND refused on the way in.
##
## Absolute filesystem paths are dropped too: they name the sender's disk
## (and user name) and point nowhere on the receiver's.

## The settings a player may choose to share. Device, account and location
## files are deliberately absent (window_wall.cfg is this machine's monitor
## layout; location_prefs.cfg is the home coordinates).
const SHAREABLE := [
	"perf_prefs.cfg", "ui_prefs.cfg", "sim_settings.cfg", "toolbar_prefs.cfg",
	"audio_prefs.cfg", "npc_display.cfg", "player.cfg", "planet_prefs.cfg",
	"climate_prefs.cfg", "weather_gen_engine.cfg", "extreme_weather.cfg",
	"pop_testing.cfg", "star_calibration.cfg", "solar_panel_config.cfg",
]

const TAG := "__t"


static func is_shareable(file_name: String) -> bool:
	return SHAREABLE.has(file_name)


## Read a .cfg (ours) into the transport JSON text. "" when unreadable.
static func encode_file(cfg_path: String) -> String:
	var cf := ConfigFile.new()
	if cf.load(cfg_path) != OK:
		return ""
	return JSON.stringify(encode_config(cf), "\t")


static func encode_config(cf: ConfigFile) -> Dictionary:
	var out := {}
	for sec in cf.get_sections():
		var d := {}
		for k in cf.get_section_keys(sec):
			var ok := [true]
			var v: Variant = encode_value(cf.get_value(sec, k), ok)
			if ok[0]:
				d[k] = v
		if not d.is_empty():
			out[sec] = d
	return out


## The JSON form of one value; `ok[0]` is cleared when it cannot travel.
static func encode_value(v: Variant, ok: Array) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_FLOAT:
			return v
		TYPE_INT:
			# JSON has one number type; tag ints so they come back as ints.
			return {TAG: "int", "v": [v]}
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v)
			if is_absolute_path(s):
				ok[0] = false
				return null
			return s
		TYPE_COLOR:
			var c: Color = v
			return {TAG: "Color", "v": [c.r, c.g, c.b, c.a]}
		TYPE_VECTOR2:
			var a: Vector2 = v
			return {TAG: "Vector2", "v": [a.x, a.y]}
		TYPE_VECTOR2I:
			var ai: Vector2i = v
			return {TAG: "Vector2i", "v": [ai.x, ai.y]}
		TYPE_VECTOR3:
			var b: Vector3 = v
			return {TAG: "Vector3", "v": [b.x, b.y, b.z]}
		TYPE_VECTOR3I:
			var bi: Vector3i = v
			return {TAG: "Vector3i", "v": [bi.x, bi.y, bi.z]}
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, \
				TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			# Packed arrays hold one plain element type: their elements go
			# in raw, the tag says what to rebuild.
			var raw := []
			for e in v:
				if typeof(e) == TYPE_STRING and is_absolute_path(str(e)):
					ok[0] = false
					return null
				raw.append(e)
			return {TAG: type_string(typeof(v)), "v": raw}
		TYPE_ARRAY:
			var arr := []
			for e in v:
				var r: Variant = encode_value(e, ok)
				if not ok[0]:
					return null
				arr.append(r)
			return arr
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_INT and typeof(k) != TYPE_STRING_NAME:
					ok[0] = false
					return null
				var r2: Variant = encode_value(v[k], ok)
				if not ok[0]:
					return null
				d[str(k)] = r2
			if d.has(TAG):
				ok[0] = false
				return null
			return d
	ok[0] = false
	return null


## Decode transport JSON text into a ConfigFile, or null when it is not a
## well-formed primitive document (the whole file is refused, not patched).
static func decode_text(text: String) -> ConfigFile:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return null
	var cf := ConfigFile.new()
	for sec in parsed:
		var d: Variant = parsed[sec]
		if not d is Dictionary:
			return null
		for k in d:
			var ok := [true]
			var v: Variant = decode_value(d[k], ok)
			if not ok[0]:
				return null
			cf.set_value(str(sec), str(k), v)
	return cf


static func decode_value(v: Variant, ok: Array) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return v
		TYPE_FLOAT:
			return v
		TYPE_ARRAY:
			var arr := []
			for e in v:
				arr.append(decode_value(e, ok))
				if not ok[0]:
					return null
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = v
			if d.has(TAG):
				return _decode_tagged(str(d[TAG]), d.get("v", null), ok)
			var out := {}
			for k in d:
				out[str(k)] = decode_value(d[k], ok)
				if not ok[0]:
					return null
			return out
	ok[0] = false
	return null


static func _decode_tagged(t: String, raw: Variant, ok: Array) -> Variant:
	if not raw is Array:
		ok[0] = false
		return null
	var a: Array = raw
	for e in a:
		if t != "PackedStringArray" and typeof(e) != TYPE_FLOAT and typeof(e) != TYPE_INT:
			ok[0] = false
			return null
	match t:
		"int":
			if a.size() == 1:
				return int(a[0])
		"Color":
			if a.size() == 4:
				return Color(a[0], a[1], a[2], a[3])
		"Vector2":
			if a.size() == 2:
				return Vector2(a[0], a[1])
		"Vector2i":
			if a.size() == 2:
				return Vector2i(int(a[0]), int(a[1]))
		"Vector3":
			if a.size() == 3:
				return Vector3(a[0], a[1], a[2])
		"Vector3i":
			if a.size() == 3:
				return Vector3i(int(a[0]), int(a[1]), int(a[2]))
		"PackedStringArray":
			var ps := PackedStringArray()
			for e in a:
				if typeof(e) != TYPE_STRING:
					ok[0] = false
					return null
				ps.append(e)
			return ps
		"PackedFloat32Array":
			return PackedFloat32Array(a)
		"PackedFloat64Array":
			return PackedFloat64Array(a)
		"PackedInt32Array":
			return PackedInt32Array(a.map(func(x): return int(x)))
		"PackedInt64Array":
			return PackedInt64Array(a.map(func(x): return int(x)))
	ok[0] = false
	return null


## "C:/Users/x/…", "C:\\…", "/home/x/…", "\\\\server\\…" — not "user://…".
static func is_absolute_path(s: String) -> bool:
	if s.length() >= 3 and s[1] == ":" and (s[2] == "/" or s[2] == "\\"):
		return true
	return s.begins_with("/") or s.begins_with("\\\\")

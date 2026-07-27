class_name ScadRuntime
extends RefCounted

## Locates a headless OpenSCAD binary and renders a parametric .scad file to STL
## by shelling out to it (Godot has no CSG kernel; OpenSCAD's CLI is built for
## exactly this). Deliberately mirrors ClimelapseVideoEncoder's find-external-
## binary pattern (PATH -> known install dirs -> user config), and hands the
## resulting STL to StlLoader (which already parses binary/ASCII STL -> ArrayMesh,
## Z-up mm -> Y-up metres). This is the "geometry" half of the parametric store:
## we DO NOT reimplement linear_extrude / difference() etc. — we call the real
## kernel. See PARAMETRIC_STORE_PLAN.md.
##
## CLI contract used: openscad -o <out.stl> --export-format binstl \
##   -p <params.json> -P <set> <in.scad>
##
## We drive parameters through OpenSCAD's **Customizer parameter-set JSON**
## (-p/-P), NOT -D. Reason: on Windows, Godot's OS.execute mangles the embedded
## double-quotes a string define needs (`filling="no"` arrives as the bare
## variable `no` and OpenSCAD warns "unknown variable 'no'"). The parameter-set
## file carries every value as a JSON string that OpenSCAD coerces to each
## variable's declared type — exactly how the Thingiverse/OpenSCAD Customizer
## works, and immune to shell quoting. format_define() (the -D form) is retained
## for reference/tests but is not the render path.

const StlLoaderScript := preload("res://core/machines/stl_loader.gd")

## Reused by the provisioner; kept here so both agree on the managed-install root.
const MANAGED_ROOT := "user://tools/openscad"

## Name of the single parameter set we write into each temp params file.
const PARAM_SET := "simbiogenesis"


## Full path to a usable openscad binary, or "" if none found.
## Resolution order (first hit wins):
##   1. user config override  [openscad] path=   in user://terrain_config.cfg
##   2. our managed on-demand install under user://tools/openscad/<version>/
##   3. well-known system install locations
##   4. system PATH
static func find_openscad() -> String:
	var cfg_path := _read_config_path()
	if not cfg_path.is_empty():
		return cfg_path
	var managed := _find_managed()
	if not managed.is_empty():
		return managed
	var known := _find_known_install()
	if not known.is_empty():
		return known
	return _find_on_path()


static func is_available() -> bool:
	return not find_openscad().is_empty()


## Renders scad_path -> out_stl_path with the given parameter overrides.
## params: { var_name: Variant } — types drive -D quoting (see format_define).
## Returns { ok: bool, reason: String, path: String, log: String }.
## Blocking (runs OpenSCAD to completion); callers should run it off the main
## thread + show a spinner (CGAL renders take real seconds). Phase 3 wires the
## async job; Phase 0 proves the call.
static func render_to_stl(scad_path: String, params: Dictionary, out_stl_path: String,
		opts: Dictionary = {}) -> Dictionary:
	var bin := find_openscad()
	if bin.is_empty():
		return {
			"ok": false,
			"path": "",
			"log": "",
			"reason": (
				"OpenSCAD not found — install it, add it to PATH, set "
				+ "[openscad] path= in user://terrain_config.cfg, or let the game "
				+ "download it on demand (see ScadProvisioner)."
			),
		}
	var abs_scad := ProjectSettings.globalize_path(scad_path).replace("\\", "/")
	if not FileAccess.file_exists(abs_scad):
		# scad_path may already be an absolute OS path (user-uploaded / user://).
		abs_scad = scad_path.replace("\\", "/")
		if not FileAccess.file_exists(abs_scad):
			return {"ok": false, "path": "", "log": "", "reason": "scad file not found: %s" % scad_path}
	var abs_out := ProjectSettings.globalize_path(out_stl_path).replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())

	var args := PackedStringArray(["-o", abs_out])
	# Force binary STL so StlLoader's binary path is deterministic and small.
	args.append("--export-format")
	args.append("binstl")
	# Parameters via a temp Customizer parameter-set file (quoting-safe on Windows).
	var params_abs := ""
	if not params.is_empty():
		params_abs = _write_param_set(params, abs_out)
		if params_abs.is_empty():
			return {"ok": false, "path": "", "log": "", "reason": "could not write param set file"}
		args.append("-p")
		args.append(params_abs)
		args.append("-P")
		args.append(PARAM_SET)
	args.append(abs_scad)

	var output: Array = []
	var err := OS.execute(bin, args, output, true, false)
	# Temp param set has served its purpose (OS.execute is blocking); tidy up.
	if not params_abs.is_empty():
		DirAccess.remove_absolute(params_abs)
	var log := ""
	for line in output:
		log += str(line)
	if err != 0:
		return {"ok": false, "path": "", "log": log,
			"reason": "OpenSCAD failed (exit %d): %s" % [err, log.strip_edges()]}
	if not FileAccess.file_exists(abs_out):
		return {"ok": false, "path": "", "log": log,
			"reason": "OpenSCAD reported success but STL missing: %s" % out_stl_path}
	return {"ok": true, "path": out_stl_path, "log": log, "reason": ""}


## Convenience: render then build a renderable ArrayMesh via the existing
## StlLoader (reuse — same converter the CNC/print subsystem uses).
## Returns { ok, reason, mesh: ArrayMesh, stl_path }.
static func render_to_mesh(scad_path: String, params: Dictionary, out_stl_path: String,
		opts: Dictionary = {}) -> Dictionary:
	var res := render_to_stl(scad_path, params, out_stl_path, opts)
	if not res.get("ok", false):
		return {"ok": false, "reason": res.get("reason", "render failed"), "mesh": null, "stl_path": ""}
	var mesh: ArrayMesh = StlLoaderScript.build_mesh(out_stl_path)
	if mesh == null:
		return {"ok": false, "reason": "STL produced but mesh build failed", "mesh": null,
			"stl_path": out_stl_path}
	return {"ok": true, "reason": "", "mesh": mesh, "stl_path": out_stl_path}


## Builds an OpenSCAD Customizer parameter-set JSON document holding one set
## (PARAM_SET) with every value as a JSON string (OpenSCAD coerces each to its
## variable's declared type). This is the render path — quoting-safe on Windows.
static func build_param_set_json(params: Dictionary, set_name: String = PARAM_SET) -> String:
	var set_values := {}
	for key in params.keys():
		set_values[String(key)] = _param_value_string(params[key])
	var doc := {
		"parameterSets": {set_name: set_values},
		"fileFormatVersion": "1",
	}
	return JSON.stringify(doc, "  ")


## Writes the param set to a unique temp file next to the output STL; returns its
## absolute path, or "" on failure.
static func _write_param_set(params: Dictionary, near_abs_out: String) -> String:
	var dir := near_abs_out.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	# Unique-ish name so concurrent/rapid renders don't clobber each other.
	var stamp := "%d_%d" % [Time.get_ticks_usec(), hash(params)]
	var path := dir.path_join("scad_params_%s.json" % stamp)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(build_param_set_json(params))
	f.close()
	return path


## OpenSCAD Customizer parameter-set value string (all set values are JSON
## strings; OpenSCAD coerces to the variable's declared type). Note strings are
## NOT wrapped in extra quotes here — JSON.stringify quotes the value, and
## OpenSCAD keeps a string variable's value as-is.
##   50            -> "50"
##   1.9           -> "1.9"
##   "no"          -> "no"
##   true          -> "true"
##   Vector3(x,y,z)-> "[x,y,z]"
static func _param_value_string(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return String.num(value, 6)
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value)
		TYPE_VECTOR2:
			return "[%s,%s]" % [String.num(value.x, 6), String.num(value.y, 6)]
		TYPE_VECTOR3:
			return "[%s,%s,%s]" % [String.num(value.x, 6), String.num(value.y, 6), String.num(value.z, 6)]
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			var parts := PackedStringArray()
			for e in value:
				parts.append(_param_value_string(e))
			return "[%s]" % ",".join(parts)
		_:
			return String(value)


## Type-correct OpenSCAD -D value formatting for one parameter. OpenSCAD is
## typed at the CLI: numbers/bools are bare, strings must carry their own quotes,
## vectors are bracketed. Returns the full "name=value" token (one args[] element).
##   50            -> radius=50
##   1.9           -> distortion=1.9
##   "no"          -> filling="no"
##   true          -> flag=true
##   [1, 2, 3]     -> v=[1,2,3]
##   Vector3(x,y,z)-> v=[x,y,z]
static func format_define(name: String, value: Variant) -> String:
	return "%s=%s" % [name, _scad_literal(value)]


static func _scad_literal(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			# Trim to a compact, locale-independent decimal (OpenSCAD wants '.').
			var s := String.num(value, 6)
			return s
		TYPE_STRING, TYPE_STRING_NAME:
			# Escape embedded quotes/backslashes, then wrap. The wrapping quotes
			# are literal chars OpenSCAD's -D parser needs to see a string value.
			var raw := String(value)
			raw = raw.replace("\\", "\\\\").replace("\"", "\\\"")
			return "\"%s\"" % raw
		TYPE_VECTOR2:
			return "[%s,%s]" % [String.num(value.x, 6), String.num(value.y, 6)]
		TYPE_VECTOR3:
			return "[%s,%s,%s]" % [String.num(value.x, 6), String.num(value.y, 6), String.num(value.z, 6)]
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			var parts := PackedStringArray()
			for e in value:
				parts.append(_scad_literal(e))
			return "[%s]" % ",".join(parts)
		_:
			# Fallback: stringify and quote defensively.
			return "\"%s\"" % String(value).replace("\"", "\\\"")


static func _read_config_path() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://terrain_config.cfg") != OK:
		return ""
	var p := str(cfg.get_value("openscad", "path", "")).strip_edges()
	if p.is_empty() or not FileAccess.file_exists(p):
		return ""
	return p.replace("\\", "/")


## Newest managed install under user://tools/openscad/<version>/openscad(.exe).
static func _find_managed() -> String:
	var root := ProjectSettings.globalize_path(MANAGED_ROOT)
	if not DirAccess.dir_exists_absolute(root):
		return ""
	var dirs := DirAccess.get_directories_at(root)
	# Prefer the highest version-sorted directory that actually holds a binary.
	var names := Array(dirs)
	names.sort()
	names.reverse()
	for name in names:
		var cand := _binary_in_dir(root.path_join(String(name)))
		if not cand.is_empty():
			return cand
	return ""


static func _find_known_install() -> String:
	var candidates := PackedStringArray()
	if OS.get_name() == "Windows":
		candidates.append("C:/Program Files/OpenSCAD/openscad.exe")
		candidates.append("C:/Program Files (x86)/OpenSCAD/openscad.exe")
		candidates.append("C:/Program Files/OpenSCAD (Nightly)/openscad.exe")
		var local_app := OS.get_environment("LOCALAPPDATA")
		if not local_app.is_empty():
			candidates.append(local_app.replace("\\", "/").path_join("Microsoft/WinGet/Links/openscad.exe"))
	elif OS.get_name() == "macOS":
		candidates.append("/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD")
	else:
		candidates.append("/usr/bin/openscad")
		candidates.append("/usr/local/bin/openscad")
		candidates.append("/snap/bin/openscad")
	for c in candidates:
		if FileAccess.file_exists(c):
			return c.replace("\\", "/")
	return ""


static func _find_on_path() -> String:
	var out: Array = []
	var err := -1
	if OS.get_name() == "Windows":
		err = OS.execute("where", ["openscad"], out, true, false)
	else:
		err = OS.execute("which", ["openscad"], out, true, false)
	if err != 0 or out.is_empty():
		return ""
	var line := str(out[0]).strip_edges()
	if line.contains("\n"):
		line = line.split("\n")[0]
	line = line.strip_edges()
	if line.is_empty() or not FileAccess.file_exists(line):
		return ""
	return line.replace("\\", "/")


## First openscad executable directly inside dir (portable zips extract to a
## folder holding the exe, sometimes one level down).
static func _binary_in_dir(dir: String) -> String:
	var names := PackedStringArray(["openscad.exe", "openscad.com", "openscad", "OpenSCAD"])
	for n in names:
		var direct := dir.path_join(n)
		if FileAccess.file_exists(direct):
			return direct.replace("\\", "/")
	# One level down (e.g. openscad-<ver>/openscad.exe inside the version dir).
	if DirAccess.dir_exists_absolute(dir):
		for sub in DirAccess.get_directories_at(dir):
			for n in names:
				var nested := dir.path_join(String(sub)).path_join(n)
				if FileAccess.file_exists(nested):
					return nested.replace("\\", "/")
	return ""

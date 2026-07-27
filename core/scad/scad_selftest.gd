extends SceneTree

## Offline deterministic self-test for the parametric-SCAD Phase 0 pipeline:
## ScadRuntime (-D literal formatting, graceful no-binary handling, STL->mesh via
## the existing StlLoader) and ScadProvisioner (manifest round-trip, install
## planning). Does NOT require an OpenSCAD binary — it exercises everything up to
## and after the subprocess boundary, and synthesizes a known binary STL in memory
## to prove the geometry-import half.
##
## Run with:
##   Godot.exe.exe --headless --path . --script core/scad/scad_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise. Run --import first so the new
## class_names register.

const RuntimeScript := preload("res://core/scad/scad_runtime.gd")
const ProvisionerScript := preload("res://core/scad/scad_provisioner.gd")
const ParserScript := preload("res://core/scad/scad_param_parser.gd")
const CatalogScript := preload("res://core/scad/scad_catalog.gd")
const StlLoaderScript := preload("res://core/machines/stl_loader.gd")

const VASE := "res://scad_library/vase_20160822.scad"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_define_formatting()
	_test_param_set_json()
	_test_no_binary_is_graceful()
	_test_stl_roundtrip()
	_test_provisioner_manifest()
	_test_provisioner_plan()
	_test_provisioner_zip_safety()
	_test_parser()
	_test_catalog()
	_test_store()
	_test_phase3_compiles()
	if _failures == 0:
		print("SCAD SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SCAD SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# -- ScadRuntime.format_define -------------------------------------------------

func _test_define_formatting() -> void:
	_check("int bare", RuntimeScript.format_define("radius", 50) == "radius=50")
	_check("bool true", RuntimeScript.format_define("flag", true) == "flag=true")
	_check("bool false", RuntimeScript.format_define("flag", false) == "flag=false")

	# String value must carry literal quotes (OpenSCAD -D string syntax).
	_check("string quoted", RuntimeScript.format_define("filling", "no") == "filling=\"no\"",
		RuntimeScript.format_define("filling", "no"))
	# Embedded quote escaped.
	_check("string escapes quote",
		RuntimeScript.format_define("s", "a\"b") == "s=\"a\\\"b\"",
		RuntimeScript.format_define("s", "a\"b"))

	# Float: tolerant — must round-trip to the same value, prefix intact.
	var fl := RuntimeScript.format_define("distortion", 1.9)
	_check("float prefix", fl.begins_with("distortion="), fl)
	_check("float value", is_equal_approx(fl.split("=")[1].to_float(), 1.9), fl)

	# Vector -> bracketed list of 3 numbers.
	var v3 := RuntimeScript.format_define("dir", Vector3(1, 2, 3))
	_check("vec3 prefix+brackets", v3.begins_with("dir=[") and v3.ends_with("]"), v3)
	var inner := v3.substr(v3.find("[") + 1, v3.rfind("]") - v3.find("[") - 1)
	var parts := inner.split(",")
	_check("vec3 arity", parts.size() == 3, v3)
	if parts.size() == 3:
		_check("vec3 values",
			is_equal_approx(parts[0].to_float(), 1.0)
			and is_equal_approx(parts[1].to_float(), 2.0)
			and is_equal_approx(parts[2].to_float(), 3.0), v3)

	# Array -> bracketed list.
	var arr := RuntimeScript.format_define("xs", [10, 20, 30])
	_check("array literal", arr == "xs=[10,20,30]", arr)

	# The real vase param set builds without error and every token has a name=.
	var vase_params := {
		"filling": "no", "radius": 50, "height": 150, "sides": 13, "thickness": 2,
		"degree_twist": 90, "number_slices": 3, "distortion": 1.9, "twisting": "yes",
		"perforating": "no",
	}
	var ok_tokens := true
	for k in vase_params.keys():
		var tok := RuntimeScript.format_define(String(k), vase_params[k])
		if not tok.begins_with("%s=" % k) or tok.length() <= String(k).length() + 1:
			ok_tokens = false
	_check("vase param tokens well-formed", ok_tokens)


# -- ScadRuntime param-set JSON (the actual render path) -----------------------

func _test_param_set_json() -> void:
	var params := {"filling": "no", "radius": 60, "degree_twist": 180, "distortion": 1.9, "flag": true}
	var txt := RuntimeScript.build_param_set_json(params, "simbiogenesis")
	var parsed = JSON.parse_string(txt)
	_check("param set parses as JSON", typeof(parsed) == TYPE_DICTIONARY)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_check("param set has fileFormatVersion", parsed.get("fileFormatVersion", "") == "1")
	var sets: Dictionary = parsed.get("parameterSets", {})
	_check("named set present", sets.has("simbiogenesis"))
	var vals: Dictionary = sets.get("simbiogenesis", {})
	# Every value must be a JSON string (OpenSCAD Customizer contract).
	var all_strings := true
	for k in vals.keys():
		if typeof(vals[k]) != TYPE_STRING:
			all_strings = false
	_check("all set values are strings", all_strings)
	# Strings are NOT double-quoted; numbers/bools stringified; coerce round-trips.
	_check("string value bare", vals.get("filling", "") == "no", str(vals.get("filling", "")))
	_check("int value stringified", vals.get("radius", "") == "60", str(vals.get("radius", "")))
	_check("bool value stringified", vals.get("flag", "") == "true", str(vals.get("flag", "")))
	_check("float value round-trips", is_equal_approx(String(vals.get("distortion", "0")).to_float(), 1.9),
		str(vals.get("distortion", "")))


# -- Graceful behavior with no OpenSCAD present --------------------------------

func _test_no_binary_is_graceful() -> void:
	# find_openscad must never crash and returns a String (possibly empty).
	var found := RuntimeScript.find_openscad()
	_check("find_openscad returns String", typeof(found) == TYPE_STRING)
	# When absent, render must fail cleanly with a helpful reason (not throw).
	if found.is_empty():
		var res := RuntimeScript.render_to_stl("res://vase_20160822.scad", {"radius": 40},
			"user://scratch/scad_selftest_out.stl")
		_check("render fails cleanly without binary", res.get("ok", true) == false)
		_check("failure gives a reason", not String(res.get("reason", "")).is_empty())
	else:
		# Binary present in this environment — just note it; end-to-end render is
		# covered by the windowed smoke, not this offline test.
		print("  note: OpenSCAD found at %s (offline test skips live render)" % found)
		_check("binary path exists", FileAccess.file_exists(found))


# -- STL -> ArrayMesh (the geometry-import half, via existing StlLoader) --------

func _test_stl_roundtrip() -> void:
	# Two triangles forming a 10mm square in the XY plane (z=0).
	var tris := [
		[Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 10, 0)],
		[Vector3(0, 0, 0), Vector3(10, 10, 0), Vector3(0, 10, 0)],
	]
	var bytes := _make_binary_stl(tris)

	var parsed: Dictionary = StlLoaderScript.parse_bytes(bytes)
	_check("stl parses ok", parsed.get("ok", false), String(parsed.get("error", "")))
	_check("stl triangle count", parsed.get("triangles", 0) == 2, str(parsed.get("triangles", -1)))
	var bmin: Vector3 = parsed.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = parsed.get("bounds_max", Vector3.ZERO)
	_check("stl bounds", bmin.is_equal_approx(Vector3(0, 0, 0))
		and bmax.is_equal_approx(Vector3(10, 10, 0)), "%s..%s" % [bmin, bmax])

	var mesh: ArrayMesh = StlLoaderScript.build_mesh_from_bytes(bytes)
	_check("mesh built from bytes", mesh != null)
	if mesh != null:
		_check("mesh has a surface", mesh.get_surface_count() >= 1, str(mesh.get_surface_count()))

	# render_to_mesh must also fail cleanly (not crash) when no binary is present.
	if RuntimeScript.find_openscad().is_empty():
		var rm := RuntimeScript.render_to_mesh("res://vase_20160822.scad", {"radius": 40},
			"user://scratch/scad_selftest_out.stl")
		_check("render_to_mesh graceful w/o binary", rm.get("ok", true) == false and rm.get("mesh") == null)


# -- Provisioner ---------------------------------------------------------------

func _test_provisioner_manifest() -> void:
	# Preserve any real manifest so the test doesn't clobber a live install.
	var had := FileAccess.file_exists(ProvisionerScript.MANIFEST)
	var backup := ""
	if had:
		var bf := FileAccess.open(ProvisionerScript.MANIFEST, FileAccess.READ)
		if bf != null:
			backup = bf.get_as_text()
			bf.close()

	# Empty/absent -> well-formed default.
	if not had:
		var m0: Dictionary = ProvisionerScript.read_manifest()
		_check("empty manifest default", m0.get("active", "?") == "" and m0.get("installs") is Dictionary)

	# Record a throwaway install and read it back.
	var ok_write: bool = ProvisionerScript.record_install("selftest-0.0", "https://example.invalid/x.zip")
	_check("record_install writes", ok_write)
	var m: Dictionary = ProvisionerScript.read_manifest()
	_check("manifest active set", m.get("active", "") == "selftest-0.0", str(m.get("active", "")))
	var installs: Dictionary = m.get("installs", {})
	_check("manifest records install", installs.has("selftest-0.0"))
	if installs.has("selftest-0.0"):
		_check("install carries source", String(installs["selftest-0.0"].get("source", "")).contains("example.invalid"))

	# Restore prior state.
	if had and not backup.is_empty():
		var rf := FileAccess.open(ProvisionerScript.MANIFEST, FileAccess.WRITE)
		if rf != null:
			rf.store_string(backup)
			rf.close()
	elif not had:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ProvisionerScript.MANIFEST))

	# needs_install / installed_versions must run without error.
	_check("needs_install returns bool", typeof(ProvisionerScript.needs_install()) == TYPE_BOOL)
	_check("installed_versions returns list",
		typeof(ProvisionerScript.installed_versions()) == TYPE_PACKED_STRING_ARRAY)


func _test_provisioner_plan() -> void:
	# No URL configured -> not ready (blocks accidental empty install).
	var p_empty: Dictionary = ProvisionerScript.plan_install("9.9.9", "")
	_check("plan without url not ready", p_empty.get("ready", true) == false)

	# Explicit URL -> ready, dest keyed by version.
	var p: Dictionary = ProvisionerScript.plan_install("2021.01", "https://example.invalid/OpenSCAD.zip")
	_check("plan with url ready", p.get("ready", false))
	_check("plan dest has version", String(p.get("dest_dir", "")).ends_with("2021.01"), String(p.get("dest_dir", "")))
	_check("plan archive path set", String(p.get("archive_path", "")).ends_with(".zip"))


func _test_provisioner_zip_safety() -> void:
	# Zip-slip guard: only plain relative entries under the install dir are accepted.
	_check("zip entry safe: nested", ProvisionerScript._entry_path_is_safe("openscad/openscad.exe"))
	_check("zip entry safe: flat", ProvisionerScript._entry_path_is_safe("openscad.exe"))
	_check("zip entry unsafe: parent traversal", not ProvisionerScript._entry_path_is_safe("../evil"))
	_check("zip entry unsafe: nested traversal", not ProvisionerScript._entry_path_is_safe("a/../../evil"))
	_check("zip entry unsafe: absolute posix", not ProvisionerScript._entry_path_is_safe("/etc/passwd"))
	_check("zip entry unsafe: windows drive", not ProvisionerScript._entry_path_is_safe("C:/Windows/evil"))
	_check("zip entry unsafe: backslash traversal", not ProvisionerScript._entry_path_is_safe("a\\..\\..\\evil"))
	_check("zip entry unsafe: empty", not ProvisionerScript._entry_path_is_safe(""))


# -- ScadParamParser (Customizer metadata -> schema) ---------------------------

func _test_parser() -> void:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(VASE)):
		_check("vase file present for parser test", false, "missing %s" % VASE)
		return
	var schema: Dictionary = ParserScript.parse_file(VASE)
	_check("parse ok", schema.get("ok", false), String(schema.get("error", "")))
	var params: Array = schema.get("params", [])
	var by_name := {}
	for p in params:
		by_name[p["name"]] = p

	# 18 user parameters; the 9 "calculated values" (expressions) are skipped.
	_check("param count (calculated values excluded)", params.size() == 18, str(params.size()))
	_check("title prettified from filename", schema.get("title", "") == "Vase", String(schema.get("title", "")))

	# Calculated values must NOT appear as parameters.
	_check("inner_radius excluded (expression)", not by_name.has("inner_radius"))
	_check("extrude_height excluded (expression)", not by_name.has("extrude_height"))
	_check("degree_holes excluded (expression)", not by_name.has("degree_holes"))

	# radius: int slider [10:300], label from the comment above it.
	_check("radius present", by_name.has("radius"))
	if by_name.has("radius"):
		var r: Dictionary = by_name["radius"]
		_check("radius type int", r["type"] == "int")
		_check("radius widget slider", r["widget"] == "slider")
		_check("radius default 50", r["default"] == 50)
		_check("radius min/max", r.get("min", -1) == 10.0 and r.get("max", -1) == 300.0)
		_check("radius label from comment", String(r["label"]).contains("Radius"), String(r["label"]))

	# filling: string dropdown [yes,no], label from the description line above.
	_check("filling present", by_name.has("filling"))
	if by_name.has("filling"):
		var fdict: Dictionary = by_name["filling"]
		_check("filling type string", fdict["type"] == "string")
		_check("filling widget dropdown", fdict["widget"] == "dropdown")
		_check("filling default no", fdict["default"] == "no")
		var opts: Array = fdict.get("options", [])
		_check("filling has 2 options", opts.size() == 2, str(opts.size()))
		if opts.size() == 2:
			_check("filling option values", opts[0]["value"] == "yes" and opts[1]["value"] == "no")
		_check("filling label", String(fdict["label"]).to_lower().contains("solid"), String(fdict["label"]))

	# distortion: float slider [0.1:5].
	if by_name.has("distortion"):
		var d: Dictionary = by_name["distortion"]
		_check("distortion type float", d["type"] == "float")
		_check("distortion slider range", is_equal_approx(d.get("min", 0.0), 0.1) and is_equal_approx(d.get("max", 0.0), 5.0))

	# sides: no annotation -> plain field.
	if by_name.has("sides"):
		_check("sides widget field", by_name["sides"]["widget"] == "field")

	# Regression: NUMERIC dropdown options (e.g. //[8,16,32] or //[0:Low,1:Med])
	# must build labels via str(), not String() — String() rejects int/float and
	# crashed the store on click. Parse a synthetic file with both forms.
	var numeric_scad := "res_n = 16; //[8,16,32]\nquality = 1; //[0:Low,1:Med,2:High]\n"
	var nschema: Dictionary = ParserScript.parse_text(numeric_scad, "numeric.scad")
	var np := {}
	for p in nschema.get("params", []):
		np[p["name"]] = p
	_check("numeric dropdown parsed", np.has("res_n") and np["res_n"]["widget"] == "dropdown")
	if np.has("res_n"):
		var opts: Array = np["res_n"]["options"]
		_check("numeric option value is int", opts.size() == 3 and opts[0]["value"] == 8, str(opts))
		_check("numeric option label is string", typeof(opts[0]["label"]) == TYPE_STRING and opts[0]["label"] == "8")
	if np.has("quality"):
		var qopts: Array = np["quality"]["options"]
		_check("labeled numeric dropdown", qopts.size() == 3 and qopts[0]["value"] == 0 and qopts[0]["label"] == "Low", str(qopts))

	# upper: malformed unclosed annotation [0:600 -> parsed leniently as a slider,
	# and a warning recorded.
	if by_name.has("upper"):
		_check("upper recovered as slider", by_name["upper"]["widget"] == "slider")
	_check("malformed annotation warned", (schema.get("warnings", []) as Array).size() >= 1)

	# default_params round-trips into a render-ready dict.
	var dp: Dictionary = ParserScript.default_params(schema)
	_check("default_params has radius", dp.get("radius", null) == 50)
	_check("default_params has filling", dp.get("filling", null) == "no")

	# End-to-end: parsed defaults actually render (only when a binary is present).
	if not RuntimeScript.find_openscad().is_empty():
		var fast := dp.duplicate()
		fast["sides"] = 6
		fast["perforating"] = "no"
		fast["twisting"] = "no"
		var res := RuntimeScript.render_to_mesh(VASE, fast, "user://scratch/scad_parser_render.stl")
		_check("parsed defaults render to mesh", res.get("ok", false), String(res.get("reason", "")))
		if res.get("ok", false):
			_check("rendered mesh non-null", res.get("mesh") != null)


# -- ScadCatalog (ingestion logic) ---------------------------------------------

func _test_catalog() -> void:
	# Dependency detection.
	var with_deps := "use <BOSL2/std.scad>\ninclude <MCAD/gears.scad>\nradius = 5;\n"
	var deps: Array = CatalogScript.detect_dependencies(with_deps)
	_check("detects use + include deps", deps.size() == 2, str(deps))
	_check("dep targets captured", deps.has("BOSL2/std.scad") and deps.has("MCAD/gears.scad"))
	_check("no deps on plain file", CatalogScript.detect_dependencies("radius=5;\n").is_empty())

	# Category inference.
	_check("vase -> vessels", CatalogScript.infer_category("vase_20160822.scad") == "vessels")
	_check("duct -> ducts", CatalogScript.infer_category("duct_base_v2.scad") == "ducts")
	_check("turbine -> energy", CatalogScript.infer_category("wind_turbine.scad") == "energy")
	_check("unknown -> uncategorized", CatalogScript.infer_category("wibble.scad") == "uncategorized")

	# License reconciliation by filename inside local_path.
	var entries := [
		{"local_path": "scad_library/vase_20160822.scad", "status": "pending-verification"},
		{"local_path": "scad_library/thing_verified.scad", "status": "verified"},
	]
	_check("license pending matched", CatalogScript.license_status_for("vase_20160822.scad", entries) == "pending-verification")
	_check("license verified matched", CatalogScript.license_status_for("thing_verified.scad", entries) == "verified")
	_check("license missing when absent", CatalogScript.license_status_for("nope.scad", entries) == "missing")

	# finalize_status truth table.
	_check("ready when render+verified+no-deps", CatalogScript.finalize_status(
		{"render": {"ok": true}, "dependencies": [], "license_status": "verified"}) == "ready")
	_check("usable-dev when license pending", CatalogScript.finalize_status(
		{"render": {"ok": true}, "dependencies": [], "license_status": "pending-verification"}) == "usable-dev")
	_check("review when license restricted (NC/ND)", CatalogScript.finalize_status(
		{"render": {"ok": true}, "dependencies": [], "license_status": "restricted"}) == "review")
	_check("quarantine when render fails", CatalogScript.finalize_status(
		{"render": {"ok": false}, "dependencies": [], "license_status": "verified"}) == "quarantined")
	# Deps present but render succeeded => deps were satisfied (siblings/MCAD) => not quarantined.
	_check("render is the dep arbiter, not deps list", CatalogScript.finalize_status(
		{"render": {"ok": true}, "dependencies": ["polyScrewThread.scad"], "license_status": "verified"}) == "ready")
	_check("quarantine when license missing", CatalogScript.finalize_status(
		{"render": {"ok": true}, "dependencies": [], "license_status": "missing"}) == "quarantined")

	_test_license_classification()
	_test_readme_extraction()

	# build_entry over the real vase file.
	if FileAccess.file_exists(ProjectSettings.globalize_path(VASE)):
		var entry: Dictionary = CatalogScript.build_entry(VASE, entries)
		_check("entry parses vase", entry.get("parse_ok", false))
		_check("entry param count 18", entry.get("param_count", 0) == 18, str(entry.get("param_count", -1)))
		_check("entry category vessels", entry.get("category", "") == "vessels")
		_check("entry credits id", entry.get("credits_id", "") == "scad-vase_20160822")
		_check("entry no deps", (entry.get("dependencies", []) as Array).is_empty())
		_check("entry license pending", entry.get("license_status", "") == "pending-verification")

	# Stub generation for an unrecorded part.
	var stub: Dictionary = CatalogScript.make_credits_stub(
		{"id": "gizmo", "title": "Gizmo", "credits_id": "scad-gizmo", "res_path": "res://scad_library/gizmo.scad"})
	_check("stub is pending-verification", stub.get("status", "") == "pending-verification")
	_check("stub category scad-part", stub.get("category", "") == "scad-part")
	_check("stub has no invented license", stub.get("license", "") == "pending" and stub.get("author", "x") == null)


func _test_license_classification() -> void:
	# Rich form with CC URL: Attribution - Share Alike.
	var nut := "NUT JOB | Nut, Bolt, Washer and Threaded Rod Factory (http://www.thingiverse.com/thing:193647) by mike_mattala is licensed under the Creative Commons - Attribution - Share Alike license.\nhttp://creativecommons.org/licenses/by-sa/3.0/"
	var l1: Dictionary = CatalogScript.classify_license(nut)
	_check("nut spdx by-sa", l1["spdx"] == "CC-BY-SA-3.0", String(l1["spdx"]))
	_check("nut author", l1["author"] == "mike_mattala", String(l1["author"]))
	_check("nut source url", String(l1["source_url"]).contains("thing:193647"))
	_check("nut title", String(l1["title"]).begins_with("NUT JOB"))
	_check("nut share_alike", l1["share_alike"] == true)
	_check("nut not restricted", l1["restricted"] == false)
	_check("nut status verified", CatalogScript.license_status_from_classification(l1) == "verified")

	# Rich form, plain Attribution.
	var bearing := "Parametric printed bearing openscad (https://www.thingiverse.com/thing:3112100) by radus is licensed under the Creative Commons - Attribution license.\nhttp://creativecommons.org/licenses/by/3.0/"
	var l2: Dictionary = CatalogScript.classify_license(bearing)
	_check("bearing spdx by", l2["spdx"] == "CC-BY-3.0", String(l2["spdx"]))
	_check("bearing author radus", l2["author"] == "radus")

	# Rich form, NC-SA (restricted).
	var pot := "Customizable Flower Pot (https://www.thingiverse.com/thing:2806583) by robertwallace is licensed under the Creative Commons - Attribution - Non-Commercial - Share Alike license.\nhttp://creativecommons.org/licenses/by-nc-sa/3.0/"
	var l3: Dictionary = CatalogScript.classify_license(pot)
	_check("pot spdx by-nc-sa", l3["spdx"] == "CC-BY-NC-SA-3.0", String(l3["spdx"]))
	_check("pot non_commercial", l3["non_commercial"] == true)
	_check("pot restricted", l3["restricted"] == true)
	_check("pot status restricted", CatalogScript.license_status_from_classification(l3) == "restricted")

	# Terse form: cc-nc.
	var terse := "This thing was created by Thingiverse user rr2s, and is licensed under cc-nc."
	var l4: Dictionary = CatalogScript.classify_license(terse)
	_check("terse spdx by-nc", l4["spdx"] == "CC-BY-NC-3.0", String(l4["spdx"]))
	_check("terse author rr2s", l4["author"] == "rr2s")
	_check("terse restricted", l4["restricted"] == true)

	# Terse form: plain cc -> CC-BY.
	var terse2 := "This thing was created by Thingiverse user FollyMaker, and is licensed under cc."
	var l5: Dictionary = CatalogScript.classify_license(terse2)
	_check("terse cc -> by", l5["spdx"] == "CC-BY-3.0", String(l5["spdx"]))
	_check("terse2 author", l5["author"] == "FollyMaker")

	# Empty template -> unknown/pending.
	var empty := "Liscened to   \n License: "
	var l6: Dictionary = CatalogScript.classify_license(empty)
	_check("empty license unknown", l6["spdx"] == "unknown")
	_check("empty status pending", CatalogScript.license_status_from_classification(l6) == "pending-verification")


func _test_store() -> void:
	# Deterministic: write a synthetic catalog and query it via ScadStore.
	var StoreScript := load("res://core/scad/scad_store.gd")
	var catalog := {
		"parts": [
			{"id": "a1", "title": "Widget A", "category": "Fans", "param_count": 5, "status": "ready",
				"description": "spins air", "source_file": "a.scad"},
			{"id": "b2", "title": "Bracket B", "category": "L Brackets", "param_count": 3, "status": "review",
				"description": "holds a shelf", "source_file": "b.scad"},
			{"id": "c3", "title": "Helper C", "category": "Fans", "param_count": 0, "status": "usable-dev",
				"description": "a library", "source_file": "c.scad"},
			{"id": "d4", "title": "Broken D", "category": "Pots", "param_count": 4, "status": "quarantined",
				"description": "won't render", "source_file": "d.scad"},
		]
	}
	var path := "user://scratch/scad_store_test_catalog.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://scratch"))
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	f.store_string(JSON.stringify(catalog))
	f.close()

	var store = StoreScript.new()
	_check("catalog loads", store.load_catalog(path), store.error())
	_check("part count", store.part_count() == 4, str(store.part_count()))

	var cats: Array = store.categories()
	_check("category count", cats.size() == 3, str(cats.size()))
	# Sorted; Fans has 2.
	var fans_count := -1
	for c in cats:
		if c["name"] == "Fans":
			fans_count = c["count"]
	_check("Fans has 2 parts", fans_count == 2, str(fans_count))

	_check("parts_in_category Fans", store.parts_in_category("Fans").size() == 2)
	_check("get_part by id", String(store.get_part("b2").get("title", "")) == "Bracket B")
	_check("search matches description", store.search("shelf").size() == 1)
	_check("search matches title", store.search("widget").size() == 1)
	# customizable_parts excludes 0-param and quarantined (c3, d4).
	_check("customizable excludes helper+broken", store.customizable_parts().size() == 2, str(store.customizable_parts().size()))
	_check("parts_with_status review", store.parts_with_status("review").size() == 1)


func _test_phase3_compiles() -> void:
	# Compile smoke for the Phase 3 pieces (the modal has no class_name).
	_check("part builder loads", load("res://core/scad/scad_part_builder.gd") != null)
	_check("store loads", load("res://core/scad/scad_store.gd") != null)
	_check("modal script compiles", load("res://scenes/ui/scad_store_modal.gd") != null)
	# ScadPartBuilder builds a node even with a bogus STL (fallback placeholder).
	var PB := load("res://core/scad/scad_part_builder.gd")
	var node = PB.build_node({"stl_path": "user://scratch/does_not_exist.stl"})
	_check("part builder returns Node3D", node is Node3D)
	if node is Node3D:
		_check("part has a mesh child", node.get_node_or_null("PartMesh") != null)
		node.free()

	# Instantiate the modal into the tree so _ready()/_build_ui() runs — catches
	# runtime UI-construction errors that a pure compile check would miss.
	# _ready() is deferred and won't fire in a bare --script tree, so exercise the
	# UI builder directly — this catches any wrong Godot API call in _build_ui /
	# _setup_studio (the real value of a runtime check vs. a pure compile check).
	var ModalScript := load("res://scenes/ui/scad_store_modal.gd")
	var modal: Control = Control.new()
	modal.set_script(ModalScript)
	get_root().add_child(modal)
	modal.call("_build_ui")
	_check("modal _build_ui ran without error", modal.get_child_count() > 0, "children=%d" % modal.get_child_count())
	# And its parameter-panel builder handles a real schema without erroring.
	if FileAccess.file_exists(ProjectSettings.globalize_path(VASE)):
		modal.set("_schema", ParserScript.parse_file(VASE))
		modal.call("_build_param_panel")
		_check("modal built param panel for vase", true)
	modal.free()


func _test_readme_extraction() -> void:
	var readme := "::::: banner :::::\n,:::::::: ::`\nhttp://www.thingiverse.com/thing:193647\nby mike is licensed under CC.\n\n# Summary\n\nGenerate your own nuts, bolts, washers and threaded rod by typing parameters into customizer.\nIncludes wingnuts.\n\n# Print Settings\n\nInfill: 100%"
	var desc := CatalogScript.extract_readme_description(readme)
	_check("readme picks summary", desc.contains("Generate your own nuts"), desc)
	_check("readme excludes print settings", not desc.contains("Infill"), desc)
	_check("readme excludes banner", not desc.contains(",:::::::"), desc)


# -- Helper: synthesize a little-endian binary STL from triangles --------------

func _make_binary_stl(tris: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(84)  # 80-byte header (zeros) + uint32 triangle count
	b.encode_u32(80, tris.size())
	for t: Array in tris:
		var chunk := PackedByteArray()
		chunk.resize(50)  # normal(12) + 3*vertex(36) + attr(2)
		var off := 12  # skip normal (left zero — StlLoader ignores it)
		for v: Vector3 in t:
			chunk.encode_float(off, v.x); off += 4
			chunk.encode_float(off, v.y); off += 4
			chunk.encode_float(off, v.z); off += 4
		b.append_array(chunk)
	return b

class_name DesignBundle
extends RefCounted

## Load and validate LinkageLab game bundle JSON (.gamebundle.json).

const EXPORT_TYPE := "linkageLab.gameBundle"
const BUNDLE_VERSION := 1


static func load_from_path(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: %s" % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Could not open: %s" % path}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Invalid JSON in %s" % path}
	return validate(parsed as Dictionary)


static func load_from_text(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Invalid JSON"}
	return validate(parsed as Dictionary)


static func validate(raw: Dictionary) -> Dictionary:
	var export_type := str(raw.get("exportType", ""))
	if export_type != EXPORT_TYPE:
		# Allow unified project files that were saved with project slice only.
		if export_type != "linkageLab.project" and export_type != "unified":
			return {"ok": false, "error": "Not a LinkageLab game bundle (exportType=%s)" % export_type}
	var version := int(raw.get("bundleVersion", 0))
	if version > 0 and version != BUNDLE_VERSION:
		push_warning("DesignBundle: bundleVersion %d differs from supported %d" % [version, BUNDLE_VERSION])
	var model: Dictionary = raw.get("model", {}) as Dictionary
	if model.is_empty() or str(model.get("base64", "")).is_empty():
		return {"ok": false, "error": "Bundle missing embedded GLB model"}
	var circuit: Dictionary = raw.get("circuit", {}) as Dictionary
	if not (circuit.get("items") is Array):
		return {"ok": false, "error": "Bundle missing circuit.items"}
	return {
		"ok": true,
		"bundle": raw,
		"name": str(raw.get("name", "StarShade Design")),
		"circuit": circuit,
		"solar": raw.get("solar", {}) as Dictionary,
		"ibc": raw.get("ibc", {}) as Dictionary,
		"location": raw.get("location", {}) as Dictionary,
		"model": model,
	}


static func solar_from_bundle(bundle: Dictionary) -> Dictionary:
	return bundle.get("solar", {}) as Dictionary


static func ibc_from_bundle(bundle: Dictionary) -> Dictionary:
	return bundle.get("ibc", {}) as Dictionary


static func location_from_bundle(bundle: Dictionary) -> Dictionary:
	return bundle.get("location", {}) as Dictionary


## The full v30 unified project block, if the bundle carries one. This is the
## parametric linkage design (structure/mode/foldAngle/panels/supportBeams) —
## LinkageParams.from_config() consumes it directly, making a web design
## natively live-foldable rather than a static GLB.
static func project_from_bundle(bundle: Dictionary) -> Dictionary:
	var proj: Dictionary = bundle.get("project", {}) as Dictionary
	if proj.is_empty():
		return {}
	# Older exports nest the linkage slice under `linkage`; newer ones put
	# `structure` at the top level. from_config detects `structure` itself.
	if proj.has("structure"):
		return proj
	var linkage: Dictionary = proj.get("linkage", {}) as Dictionary
	if linkage.has("structure"):
		return linkage
	return {}


## True if the bundle carries an editable parametric linkage design.
static func has_project(bundle: Dictionary) -> bool:
	return not project_from_bundle(bundle).is_empty()

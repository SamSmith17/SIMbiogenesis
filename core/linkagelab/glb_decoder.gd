class_name GlbDecoder
extends RefCounted

## Decode base64 GLB from a game bundle and register in ModelCatalog.


static func register_from_bundle(model: Dictionary, label: String = "") -> Dictionary:
	var b64 := str(model.get("base64", ""))
	if b64.is_empty():
		return {}
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.is_empty():
		return {}
	var fmt := str(model.get("format", "glb")).to_lower()
	var ext := "glb" if fmt != "gltf" else "gltf"
	return ModelImporter.import_glb_bytes(bytes, label, ext, true,
		float(model.get("heightM", 0.0)),
		_linkagelab_file_units_to_meters(model))


static func _linkagelab_file_units_to_meters(model: Dictionary) -> float:
	# Units multiplier is only a FALLBACK — ModelCatalog.resolved_scale prefers the
	# bundle's heightM reference fit when present, so a correct world size no longer
	# depends on this guess. Honor the declared units; default to meters (1:1).
	var units := str(model.get("units", "")).strip_edges().to_lower()
	if units in ["inch", "inches", "in"]:
		return ModelCatalog.LINKAGELAB_INCHES_TO_M
	if units in ["mm", "millimeter", "millimeters"]:
		return 0.001
	if units in ["cm", "centimeter", "centimeters"]:
		return 0.01
	if units in ["ft", "foot", "feet"]:
		return 0.3048
	return 1.0

@tool
extends EditorPlugin

## Registers SketchupGltfExtension for EDITOR imports (res:// .glb / .gltf),
## so a SketchUp export dropped into the project gets the same material fix
## the in-game importer applies to user://models (ImportMaterialFixer).
## Only files Godot (re)imports are affected: an asset imported before the
## plugin was enabled keeps its look until it is reimported
## (Reimport in the FileSystem dock, or a Godot upgrade).
##
## Project setting `simbiogenesis/import/sketchup_material_fix`:
## "auto" (default — fix files recognised as SketchUp exports), "off",
## "force".

const SETTING := "simbiogenesis/import/sketchup_material_fix"

var _ext: GLTFDocumentExtension = null


func _enter_tree() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, "auto")
	ProjectSettings.set_initial_value(SETTING, "auto")
	ProjectSettings.add_property_info({
		"name": SETTING, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM, "hint_string": "auto,off,force",
	})
	_ext = preload("res://addons/sketchup_import_fix/sketchup_gltf_extension.gd").new()
	GLTFDocument.register_gltf_document_extension(_ext, true)


func _exit_tree() -> void:
	if _ext != null:
		GLTFDocument.unregister_gltf_document_extension(_ext)
		_ext = null

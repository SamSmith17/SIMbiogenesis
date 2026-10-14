@tool
extends GLTFDocumentExtension

## Editor-import half of the SketchUp material fix: after Godot builds the
## scene from a glTF, hand it to ImportMaterialFixer when the file is a
## SketchUp export (or the project setting forces it). Registered only by the
## editor plugin — the game's own loader calls ImportMaterialFixer directly,
## where it knows the catalog entry's per-model mode.

const SETTING := "simbiogenesis/import/sketchup_material_fix"


func _import_post(state: GLTFState, root: Node) -> Error:
	var mode := str(ProjectSettings.get_setting(SETTING, "auto"))
	if not ImportMaterialFixer.should_fix(state.json, mode):
		return OK
	var rep := ImportMaterialFixer.fix_scene(root)
	print("SketchUp Import Fix: %s — %d materials %s" % [state.filename,
		int(rep.get("fixed", 0)), JSON.stringify(rep.get("profiles", {}))])
	return OK

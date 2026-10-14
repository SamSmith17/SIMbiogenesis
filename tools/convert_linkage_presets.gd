extends SceneTree
## One-off tool: convert LinkageLab web-app config JSONs into minimal v30
## presets under res://core/linkage/presets/ (round-tripped through
## LinkageParams so only in-scope fields ship). Re-run when the web configs
## change:
##   Godot.exe.exe --headless --path . --script tools/convert_linkage_presets.gd
##
## The LinkageLab `main` presets (`presets/ll_*.json`) are NOT made here: they
## come from `node tools/linkage_parity_dump.mjs`, which reads them from the
## same git ref as the parity fixtures (LINKAGE_PARITY.md). Since LinkageParams
## became lossless this tool also keeps every source key it does not model.

const SOURCE_DIR := "C:/Users/notsa/Documents/GitHub/LinkageLab/configs/"
const DEST_DIR := "res://core/linkage/presets/"

## ⚠ `starshade_soak_2026.json` is DIVERGED from its web-app source and is
## deliberately NOT regenerated here. It ships hand-corrected orientation —
## `panels.gridRotation` 22.5° (the solar grid was square to the structure) and
## `supportBeams.rcpEndOffset` 1.3 (the reciprocal beams sat at the wrong end
## offset) — and it is the design the Lab opens on by default
## (`linkage_lab_modal.gd:DEFAULT_PRESET`). Re-adding it to JOBS would silently
## revert both fixes. If the web config is ever corrected upstream, re-add it
## and re-verify the array orientation against the structure.
const JOBS := [
	{
		"src": "starshade-default.json",
		"dst": "starshade_default.json",
		"name": "StarShade Default - 8-mod Cylinder, 18 Panels",
	},
	{
		"src": "StarShade Compact 12p.json",
		"dst": "starshade_compact.json",
		"name": "StarShade Compact - 8-mod Cylinder, 12 Panels",
	},
]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEST_DIR))
	var fail := false
	for job in JOBS:
		var src_path: String = SOURCE_DIR + str(job["src"])
		var f := FileAccess.open(src_path, FileAccess.READ)
		if f == null:
			push_error("convert_linkage_presets: cannot open " + src_path)
			fail = true
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary):
			push_error("convert_linkage_presets: bad JSON in " + src_path)
			fail = true
			continue
		var p := LinkageParams.new()
		p.from_config(parsed as Dictionary)
		var cfg := p.to_config()
		cfg["name"] = str(job["name"])
		var out := FileAccess.open(DEST_DIR + str(job["dst"]), FileAccess.WRITE)
		out.store_string(JSON.stringify(cfg, "\t"))
		out.close()
		print("wrote %s (%s modules=%d fold=%.1f)" % [
			str(job["dst"]), str(job["name"]), p.modules, rad_to_deg(p.fold_angle)])
	quit(1 if fail else 0)

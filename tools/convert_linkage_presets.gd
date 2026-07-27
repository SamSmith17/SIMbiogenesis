extends SceneTree
## One-off tool: convert LinkageLab web-app config JSONs into minimal v30
## presets under res://core/linkage/presets/ (round-tripped through
## LinkageParams so only in-scope fields ship). Re-run when the web configs
## change:
##   Godot.exe.exe --headless --path . --script tools/convert_linkage_presets.gd

const SOURCE_DIR := "C:/Users/notsa/Documents/GitHub/LinkageLab/configs/"
const DEST_DIR := "res://core/linkage/presets/"

const JOBS := [
	{
		"src": "StarShade 8m Cylinder 18p - soak 26 actual.json",
		"dst": "starshade_soak_2026.json",
		"name": "StarShade V1 - SOAK 2026",
	},
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

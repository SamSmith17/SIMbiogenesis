extends SceneTree
## Packed size of every built-in designer preset: the envelope a design ships
## as (`packed_spec`) and, where the designer lists its parts, how many
## handling units PackKitter makes and their total volume. Run it on two
## checkouts to compare (it only calls what the checkout has):
##   Godot --headless --path . --script tools/diag/packed_kit_regression.gd
## One "kitreg" line per preset: id | envelope w x d x h m | envelope m3 |
## mass kg | units | kit m3.

const DESIGNERS := [
	["dome", "res://core/domelab/domelab_design.gd", "res://core/domelab/domelab_presets.gd"],
	["flatpack", "res://core/flatpack/flatpack_design.gd", "res://core/flatpack/flatpack_presets.gd"],
	["gantry", "res://core/gantrylab/gantrylab_design.gd", "res://core/gantrylab/gantrylab_presets.gd"],
	["toroid", "res://core/toroidlab/toroidlab_design.gd", "res://core/toroidlab/toroidlab_presets.gd"],
	["pv", "res://core/pvlab/pvlab_design.gd", "res://core/pvlab/pvlab_presets.gd"],
	["pelton", "res://core/peltonlab/peltonlab_design.gd", "res://core/peltonlab/peltonlab_presets.gd"],
	["wind", "res://core/windlab/windlab_design.gd", "res://core/windlab/windlab_presets.gd"],
]


func _initialize() -> void:
	print("kitreg id | envelope m | env m3 | mass kg | units | kit m3")
	for row in DESIGNERS:
		var design_scr: Script = load(row[1])
		var presets_scr: Script = load(row[2])
		if design_scr == null or presets_scr == null:
			continue
		for p in presets_scr.call("builtins"):
			var spec: Dictionary = p.get("spec", {})
			var d: Dictionary = design_scr.call("solve", spec)
			var env: Dictionary = design_scr.call("packed_spec", d)
			var parts: Array = []
			if _has(design_scr, "parts_for_packing"):
				parts = design_scr.call("parts_for_packing", d)
			_line("%s/%s" % [row[0], str(p.get("id", "?"))], env, parts)
	var rack: Script = load("res://core/terrain/pallet_rack_builder.gd")
	if rack != null:
		var specs := {"default": {}}
		if _has(rack, "chiba_2024_spec"):
			specs["chiba_2024"] = rack.call("chiba_2024_spec")
		for k in specs:
			var env: Dictionary = {}
			if _has(rack, "packed_spec_for"):
				env = rack.call("packed_spec_for", specs[k])
			else:
				env = _packed_for_model("pallet_rack")
			var parts: Array = []
			if _has(rack, "parts_for_packing"):
				parts = rack.call("parts_for_packing", specs[k])
			_line("rack/%s" % k, env, parts)
	var link: Script = load("res://core/linkage/linkage_structure_builder.gd")
	var params_scr: Script = load("res://core/linkage/linkage_params.gd")
	if link != null and params_scr != null:
		var lp: Object = params_scr.new()
		var env: Dictionary = link.call("packed_spec_for", lp)
		var parts: Array = []
		if _has(link, "parts_for_packing"):
			parts = link.call("parts_for_packing", lp)
		_line("linkage/default", env, parts)
	quit()


func _packed_for_model(model_id: String) -> Dictionary:
	var ps: Script = load("res://core/packing/packed_spec.gd")
	return ps.call("for_model", model_id) if ps != null else {}


func _has(scr: Script, fn: String) -> bool:
	for m in scr.get_script_method_list():
		if str(m.get("name", "")) == fn:
			return true
	return false


func _line(id: String, env: Dictionary, parts: Array) -> void:
	var w := float(env.get("w_m", 0.0))
	var dd := float(env.get("d_m", 0.0))
	var h := float(env.get("h_m", 0.0))
	var n := int(env.get("count", 1))
	var units := "-"
	var kit_v := "-"
	if not parts.is_empty():
		var kitter: Script = load("res://core/packing/pack_kitter.gd")
		var u: Array = kitter.call("kit", parts, {})
		var s: Dictionary = kitter.call("summary", u)
		units = str(u.size())
		kit_v = "%.3f" % float(s.get("volume_m3", 0.0))
	print("kitreg %s | %.2f x %.2f x %.2f%s | %.3f | %.1f | %s | %s" % [
		id, w, dd, h, (" x%d" % n) if n > 1 else "", w * dd * h * n,
		float(env.get("mass_kg", -1.0)), units, kit_v])

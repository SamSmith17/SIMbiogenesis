extends SceneTree

## Every designer's packing parts for its built-ins: label, kind and mass
## (resource composition plan Phase 9: what materials a structure is made
## of). Offline:
##   Godot --headless --path . --script tools/diag/parts_labels_probe.gd


func _initialize() -> void:
	var seen: Dictionary = {}
	_dump("linkage", LinkageStructureBuilder.parts_for_packing(LinkageParams.new()), seen)
	_dump("rack", PalletRackBuilder.parts_for_packing({}), seen)
	for p in DomeLabPresets.builtins():
		_dump("dome", DomeLabDesign.parts_for_packing(DomeLabDesign.solve(p["spec"])), seen)
	for p2 in FlatpackPresets.builtins():
		_dump("flatpack", FlatpackDesign.parts_for_packing(FlatpackDesign.solve(p2["spec"])), seen)
	_dump("toroid", ToroidLabDesign.parts_for_packing(ToroidLabDesign.solve({})), seen)
	_dump("pvlab", PvLabDesign.parts_for_packing(PvLabDesign.solve({})), seen)
	_dump("gantry", GantryLabDesign.parts_for_packing(GantryLabDesign.solve({})), seen)
	_dump("pelton", PeltonLabDesign.parts_for_packing(PeltonLabDesign.solve({})), seen)
	_dump("wind", WindLabDesign.parts_for_packing(WindLabDesign.solve({})), seen)
	_dump("tc", TcDesign.parts_for_packing(TcDesign.solve(TcBuilder.spec_for_model("tclab_biochar_reactor"))), seen)
	quit(0)


func _dump(who: String, parts: Array, seen: Dictionary) -> void:
	for pt in parts:
		var d: Dictionary = pt
		var key := who + "|" + str(d.get("label", ""))
		if seen.has(key):
			continue
		seen[key] = true
		print("%s\t%s\t%s\t%.3f\t%s" % [who, str(d.get("kind", "")), str(d.get("label", "")),
			float(d.get("mass_kg", 0.0)), str(d.get("material", d.get("look", "")))])

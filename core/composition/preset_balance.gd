class_name PresetBalance
extends RefCounted

## Every library preset and builtin recipe judged by MassBalance with its
## own air mode and retained elements (resource composition plan Phase 3).
## Pure: the preset audit (tools/diag/preset_balance_audit.gd) formats it,
## preset_balance_selftest holds every row to a good verdict.
##
## One row: {group, label, verdict, mb, ins, outs, air}. `verdict` is
## MassBalance's (ok / estimate / unbalanced / unknown / source / sink) or
## "runtime" when the preset lists no rates (the engine sets them live).
## Processors and machines are judged at their listed hourly rates (one
## unit), habitats per person, plants per kg of crop (MassBalance.plant_io),
## recipes per batch.

## Presets the static check lets off, with the reason: their output kind
## shares one make-up with another machine's, and their feed does not fit
## it. With composition tracked (Phase 10, MakeUp.derive_outputs) each of
## them conserves every element; make_up_selftest holds them to that.
const EXCEPTIONS := {
	# Shares the liquid_fertilizer kind with the blackwater digester, but a
	# urine-diverting toilet's brownwater carries about a third of the N:
	# one static make-up per kind cannot show both digestates.
	"Brownwater Digester (3 m³)": "digestate weaker than the shared kind's make-up",
	# Shares the biochar kind with the crop-residue reactor, whose char holds
	# that feed's ash; char from clean timber has almost none (C, H, O close).
	"Biochar Kiln (scrap lumber)": "wood char has less ash than the shared kind's make-up",
}

const GROUP_MACHINES := "Processors and machines"
const GROUP_HABITATS := "Habitats (per person)"
const GROUP_PLANTS := "Plants (per kg of crop out)"
const GROUP_RECIPES := "Builtin process recipes (per batch)"


static func rows(tol: float = MassBalance.DEFAULT_TOL) -> Array:
	var out: Array = []
	_presets(out, GROUP_MACHINES, ComponentPresets.PROCESSORS + ComponentPresets.TOOLS
		+ ComponentPresets.CSP_CONCENTRATORS, tol)
	_presets(out, GROUP_HABITATS, ComponentPresets.HABITATS, tol)
	for p in ComponentPresets.PLANTS:
		var pd: Dictionary = p
		var specs: Dictionary = pd.get("specs", {})
		var io := MassBalance.plant_io(specs)
		var air: Variant = specs.get("air", "grow")
		out.append(_row(GROUP_PLANTS, str(pd.get("label", "")), io[0], io[1], air,
			MassBalance.PLANT_RETAIN, tol))
	for r in ProcessRecipeCatalog.BUILTINS:
		var rd: Dictionary = r
		var outs: Array = []
		for o in rd.get("outputs", []):
			var od: Dictionary = (o as Dictionary).duplicate()
			if str(od.get("kind", "")) == "part":
				var pid := str(od.get("part_id", ""))
				if pid.begins_with("pp_sheet"):
					# A plastic_sheet unit is the 1 m² × 8 mm sheet; thicker
					# sheets name their thickness ("pp_sheet_15mm").
					od["kind"] = "plastic_sheet"
					od["qty"] = float(od.get("qty", 1.0)) * sheet_units(pid)
				else:
					od["kind"] = "finished_part"
			outs.append(od)
		out.append(_row(GROUP_RECIPES, "recipe: " + str(rd.get("label", rd.get("id", ""))),
			rd.get("inputs", []), outs, rd.get("air", ""), rd.get("retain", []), tol))
	return out


static func _presets(out: Array, group: String, presets: Array, tol: float) -> void:
	var seen: Dictionary = {}
	for p in presets:
		var pd: Dictionary = p
		var lbl := str(pd.get("label", ""))
		if seen.has(lbl):
			continue
		seen[lbl] = true
		var specs: Dictionary = pd.get("specs", {})
		var ins: Array = specs.get("inputs", [])
		var outs: Array = specs.get("outputs", [])
		if ins.is_empty() and outs.is_empty():
			continue
		var item := {"type": str(pd.get("type", "processor")), "specs": specs}
		out.append(_row(group, lbl, ins, outs, MassBalance.air_for(item), specs.get("retain", []), tol))


static func _row(group: String, label: String, ins: Array, outs: Array, air: Variant,
		retain: Variant, tol: float) -> Dictionary:
	var mb := MassBalance.check(ins, outs, [], [], tol, air, {"retain": retain})
	var verdict := str(mb["verdict"])
	var any := false
	for io in ins + outs:
		if float((io as Dictionary).get("rate", (io as Dictionary).get("qty", 0.0))) > 0.0:
			any = true
			break
	if verdict != "unknown" and (not any or (float((mb["in"] as Dictionary)["kg"]) <= MassBalance.FLOOR_KG
			and float((mb["out"] as Dictionary)["kg"]) <= MassBalance.FLOOR_KG)):
		verdict = "runtime"
	return {"group": group, "label": label, "verdict": verdict, "mb": mb, "ins": ins, "outs": outs, "air": air}


## plastic_sheet units in one sheet of this part (1.0 = 8 mm).
static func sheet_units(part_id: String) -> float:
	var re := RegEx.new()
	re.compile("(\\d+)\\s*mm")
	var m := re.search(part_id)
	return float(m.get_string(1)) / 8.0 if m != null else 1.0


## True for a verdict a shipped preset may carry.
static func acceptable(verdict: String) -> bool:
	return verdict in ["ok", "estimate", "source", "sink", "runtime"]

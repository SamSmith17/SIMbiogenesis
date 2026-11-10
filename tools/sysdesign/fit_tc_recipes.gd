extends SceneTree

## Run a tri-clamp designer built-in's whole batch in the TC Process Lab's
## model (headless, the same sim the designer runs) and fit it into the batch
## recipe a graph node runs (TcProcSummary.fit, "Use this run on the graph").
## Adds a crew step to load it and one to empty it, so people run the batch.
##
##   Godot --headless --path . --script tools/sysdesign/fit_tc_recipes.gd
##
## Writes tools/sysdesign/recipes/<preset>.json.

const JOBS := [
	{"preset": "biochar_reactor", "binds": "Biochar Reactor",
		"load": "Load the reactor with biomass", "unload": "Empty the char and the traps"},
	{"preset": "plastic_retort", "binds": "Plastic-to-Fuel Retort",
		"load": "Load the retort with shredded plastic", "unload": "Drain the oil and wax"},
]
const SAMPLE_S := 60.0
const LOAD_H := 0.3
const UNLOAD_H := 0.3


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://tools/sysdesign/recipes")
	for job: Dictionary in JOBS:
		var spec := TcPresets.builtin(str(job["preset"]))
		var pr := TcProcSpec.resolve(spec.get("process", {}))
		var d := TcDesign.solve(spec)
		d = d.duplicate()
		d["spec"] = spec
		var sim := TcProcSim.create(d, pr)
		var history: Array = []
		var next := 0.0
		var end := float(pr["duration_h"]) * 3600.0
		while sim.t_s < end - 1e-6:
			sim.step(minf(TcProcSim.DT_DEFAULT, end - sim.t_s))
			if sim.t_s >= next - 1e-6:
				next = sim.t_s + SAMPLE_S
				var r := sim.readings()
				var ckg := 0.0
				for k in (r.get("condensate_total", {}) as Dictionary).keys():
					ckg += float(r["condensate_total"][k])
				history.append({"t_h": sim.t_s / 3600.0,
					"gas": float(r.get("gas_out_l_min", 0.0)), "gas_dry": float(r.get("gas_out_dry_l_min", 0.0)),
					"lhv": float(r.get("gas_lhv_mj_nm3", 0.0)), "cond": ckg, "char": float(r.get("char_kg", 0.0)),
					"moisture": float(r.get("moisture_kg", 0.0)), "e_kwh": float(r.get("energy_in_kwh", 0.0))})
		var preset := ComponentPresets.find_preset_by_label(str(job["binds"]))
		var ps: Dictionary = preset.get("specs", {})
		var recipe := TcProcSummary.fit(d, pr, sim, history, sim.events.duplicate(true),
			ps.get("inputs", []) as Array, ps.get("outputs", []) as Array)
		var steps: Array = [{"id": "load", "label": str(job["load"]), "at_frac": 0.0, "chore_hours": LOAD_H}]
		for s in (recipe.get("steps", []) as Array):
			steps.append(s)
		steps.append({"id": "unload", "label": str(job["unload"]), "at_frac": 1.0, "chore_hours": UNLOAD_H})
		recipe["steps"] = steps
		recipe["chore_hours"] = LOAD_H + UNLOAD_H
		var keep := {"watts": recipe.get("watts", 0.0), "gas_lhv_mj_nm3": recipe.get("gas_lhv_mj_nm3", 0.0),
			"gas_composition": recipe.get("gas_composition", {}), "tc_summary": recipe.get("tc_summary", {})}
		recipe = ProcessRecipe.normalize(recipe).merged(keep)
		var path := "res://tools/sysdesign/recipes/%s.json" % str(job["preset"])
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(recipe, "  "))
		f.close()
		print("fit %s: %s" % [str(job["preset"]), str(recipe.get("note", ""))])
		print("   in  ", recipe.get("inputs", []))
		print("   out ", recipe.get("outputs", []))
	quit(0)

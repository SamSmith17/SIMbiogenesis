extends RefCounted

## Mount Vernon (2026-10-13): stamps the JA Solar 380 W module's own
## temperature coefficients (Voc −0.272 %/°C, Pmax −0.35 %/°C) onto the 9S
## array added by mtvernon_solar_eg4.gd, so the string Voc check and the
## 6000XP's MPPT window check use them instead of the generic 0.3 %/°C.
## Touches nothing else. Idempotent.

const ARRAY_TAG := "pv_mtvernon_main"


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "why": "no graph view"}
	var model: Object = sgv.get("model")
	var pv_specs: Dictionary = {}
	for p: Dictionary in ComponentPresets.PANELS:
		if str(p.get("label", "")) == "JA Solar 380W":
			pv_specs = p.get("specs", {}) as Dictionary
	var done: Array = []
	for it: Dictionary in model.get("items"):
		var asp: Dictionary = it.get("specs", {}) as Dictionary
		if str(asp.get("array_tag", "")) != ARRAY_TAG:
			continue
		var nsp: Dictionary = asp.duplicate(true)
		nsp["voc_temp_coeff_pct"] = float(pv_specs.get("voc_temp_coeff_pct", -0.272))
		nsp["pmax_temp_coeff_pct"] = float(pv_specs.get("pmax_temp_coeff_pct", -0.35))
		model.call("update_item", str(it.get("id", "")), {"specs": nsp})
		done.append("array %s: Voc %.3f %%/°C, Pmax %.3f %%/°C" % [str(it.get("id", "")),
				float(nsp["voc_temp_coeff_pct"]), float(nsp["pmax_temp_coeff_pct"])])
	if done.is_empty():
		return {"ok": false, "why": "array %s not found" % ARRAY_TAG}
	# Report the controller's string check with the new coefficients.
	var flat: Array = GraphNesting.flat_connections(model as GraphModel)
	var rep := PvElectrical.string_window_report(model as GraphModel, "starshade_ctrl", flat)
	print("mtvernon_pv_coeffs: string check %s" % JSON.stringify(rep))
	sgv.set("_autosave_pending", true)
	sgv.call("_flush_graph_autosave")
	for line in done:
		print("mtvernon_pv_coeffs: ", line)
	return {"ok": not rep.is_empty() and bool(rep.get("ok", false)), "done": done}

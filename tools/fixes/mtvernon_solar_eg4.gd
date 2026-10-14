extends RefCounted

## Mount Vernon's real power system (user, 2026-10-12): 9 × 380 W modules in
## series, an EG4 6000XP, a 48 V EG4 20.8 kWh LiFePO4 bank.
##  - the controller node (starshade_ctrl) takes the 6000XP's data-sheet specs
##    (ComponentPresets "EG4 6000XP") and loses its StarShade identity, so the
##    StarShade seeder can never clear it as seeded content;
##  - starshade_bat_a becomes the 20.8 kWh bank; starshade_bat_b and its two
##    wires are removed (one bank node — capacity is what the model uses);
##  - a 9S × 380 W array (JA Solar JAM60S20 figures, editable) is added, wired
##    PV+/PV− to the 6000XP, facing south at 35° until it is placed in 3D
##    (inspector → "Place array in 3D": its rack's facing then drives it).
## Idempotent: re-running finds the array by its tag and re-specs the rest.

const CTRL := "starshade_ctrl"
const BAT_KEEP := "starshade_bat_a"
const BAT_DROP := "starshade_bat_b"
const ARRAY_TAG := "pv_mtvernon_main"


func _preset(list: Array, label: String) -> Dictionary:
	for p: Dictionary in list:
		if str(p.get("label", "")) == label:
			return (p.get("specs", {}) as Dictionary).duplicate(true)
	return {}


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return {"ok": false, "why": "no graph view"}
	var model: Object = sgv.get("model")
	var done: Array = []

	var ctrl_specs := _preset(ComponentPresets.CONTROLLERS, "EG4 6000XP")
	var bat_specs := _preset(ComponentPresets.BATTERIES, "EG4 48V 20.8 kWh Bank")
	var pv_specs := _preset(ComponentPresets.PANELS, "JA Solar 380W")
	if ctrl_specs.is_empty() or bat_specs.is_empty() or pv_specs.is_empty():
		return {"ok": false, "why": "presets missing"}

	# 1. Controller → EG4 6000XP (keep id, position, wiring).
	var ctrl: Dictionary = model.call("get_item", CTRL)
	if ctrl.is_empty() or str(ctrl.get("type", "")) != "controller":
		return {"ok": false, "why": "controller %s not found" % CTRL}
	var cs: Dictionary = (ctrl.get("specs", {}) as Dictionary).duplicate(true)
	for k in ctrl_specs.keys():
		cs[k] = ctrl_specs[k]
	cs.erase("starshade_tag")
	cs["source"] = "user"
	cs.erase("destroyed")
	model.call("update_item", CTRL, {"specs": cs})
	done.append("controller → %s" % str(cs.get("name", "")))

	# 2. Battery bank → one 20.8 kWh node.
	var bat: Dictionary = model.call("get_item", BAT_KEEP)
	if not bat.is_empty():
		var bs: Dictionary = (bat.get("specs", {}) as Dictionary).duplicate(true)
		var soc := float(bs.get("soc", 0.5))
		for k in bat_specs.keys():
			bs[k] = bat_specs[k]
		bs["soc"] = soc
		bs.erase("starshade_tag")
		bs["source"] = "user"
		model.call("update_item", BAT_KEEP, {"specs": bs})
		done.append("battery → %s" % str(bs.get("name", "")))
	if not (model.call("get_item", BAT_DROP) as Dictionary).is_empty():
		model.call("remove_item", BAT_DROP)
		done.append("removed second 2.56 kWh battery %s" % BAT_DROP)

	# 3. The 9S × 380 W array wired to the 6000XP.
	var have_array := false
	for it: Dictionary in model.get("items"):
		var asp: Dictionary = it.get("specs", {}) as Dictionary
		if str(asp.get("array_tag", "")) == ARRAY_TAG:
			have_array = true
			# The panel's own temperature coefficients (added 2026-10-13): the
			# string Voc check and the MPPT window read them.
			if not asp.has("voc_temp_coeff_pct"):
				var nsp: Dictionary = asp.duplicate(true)
				nsp["voc_temp_coeff_pct"] = float(pv_specs.get("voc_temp_coeff_pct", -0.272))
				nsp["pmax_temp_coeff_pct"] = float(pv_specs.get("pmax_temp_coeff_pct", -0.35))
				model.call("update_item", str(it.get("id", "")), {"specs": nsp})
				done.append("array %s: panel temperature coefficients" % str(it.get("id", "")))
	if not have_array:
		var aid := str(sgv.call("add_imported_solar_panels", 9, float(pv_specs["wmp"]),
				"JA Solar 380W", ARRAY_TAG, {
					"voc": float(pv_specs["voc"]), "vmp": float(pv_specs["vmp"]),
					"isc": float(pv_specs["isc"]), "imp": float(pv_specs["imp"]),
					"voc_temp_coeff_pct": float(pv_specs.get("voc_temp_coeff_pct", -0.272)),
					"pmax_temp_coeff_pct": float(pv_specs.get("pmax_temp_coeff_pct", -0.35)),
					"panel_w_m": PvArrayBuilder.DEFAULT_PANEL_W_M,
					"panel_h_m": PvArrayBuilder.DEFAULT_PANEL_H_M,
					"tilt_deg": 35.0, "azimuth_deg": 180.0,
					"mount_style": SolarArrayBuilder.MOUNT_GROUND,
					"controller_id": CTRL, "show_picker": false,
				}))
		var arr: Dictionary = model.call("get_item", aid)
		done.append("added array %s (%s)" % [aid,
				str((arr.get("specs", {}) as Dictionary).get("array_topology", "?"))])
	if sgv.has_method("_sync_solar_ui_from_graph"):
		sgv.call("_sync_solar_ui_from_graph")
	if sgv.has_method("_flush_graph_autosave"):
		sgv.set("_autosave_pending", true)
		sgv.call("_flush_graph_autosave")
	for line in done:
		print("mtvernon_solar_eg4: ", line)
	return {"ok": true, "done": done}

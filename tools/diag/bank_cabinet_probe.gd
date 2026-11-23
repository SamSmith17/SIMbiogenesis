extends SceneTree

## Headless probe (not a selftest): a 1S4P rack-pack cabinet bank — the
## side bars, the frame boxes, the switch and every cable's bend radius
## against its minimum. Run after any change to BankDesign's cabinet rules:
##   godot --headless --path . --script tools/diag/bank_cabinet_probe.gd

func _initialize() -> void:
	var b := BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, 4, "probe")
	var d := BankDesign.solve(b)
	var bars: Dictionary = d["bars"]
	print("bars w %.1f n %d pos_line %.1f neg_line %.1f lo %.1f hi %.1f land_up %.1f" % [float(bars["w"]), int(bars["n"]), float(bars["pos_line"]), float(bars["neg_line"]), float(bars["lo"]), float(bars["hi"]), float(bars.get("land_up", 0.0))])
	for f in (d["frame"]["boxes"] as Array):
		print("frame %s %s" % [f["id"], f["box"]])
	print("disc ", d["disconnect"])
	for cb in (d["cables"] as Array):
		var e0: Dictionary = cb["ends"][0]
		var e1: Dictionary = cb["ends"][1]
		print("%s min_r %.1f r %.1f tight %s  a %s t %s  b %s t %s k %.1f" % [cb["id"], float(cb["min_r"]), float(cb["r_bend"]), str(cb.get("tight", false)), e0["p"], e0.get("t", Vector3.ZERO), e1.get("p", Vector3.ZERO), e1.get("t", Vector3.ZERO), float(cb.get("k", 0.0))])
	for f in (d["fuses"] as Array):
		print("fuse %s a %s in %s axis %s" % [f["id"], f["a"], f["in"], f["axis"]])
	quit(0)

extends RefCounted

## Bombay Beach (2026-10-21): the washes run only when rain reaches them.
## Turns on "Dry between storms" (streams with no base flow of their own carry
## nothing between storms) and sets the water display back to All streams (the
## world had it Off). Both are WaterFeatureLayer settings, saved by the water
## network's own setters. Idempotent.
##   tools\harness.ps1 -World w6ad922917357 -RunScript res://tools/fixes/bombay_beach_dry_storms.gd [-Persist]


func run(main: Node, _harness: Node) -> Dictionary:
	await main.get_tree().process_frame
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader == null or not loader.has_method("water_network"):
		return {"ok": false, "why": "no water network"}
	var wn: Node = loader.call("water_network")
	var lay: WaterFeatureLayer = wn.get("layer")
	print("bb-dry: before dry_between_storms=%s display_mode=%s" % [
		str(lay.setting("dry_between_storms")), str(lay.setting("display_mode"))])
	wn.call("set_dry_between_storms", true)
	wn.call("set_display_mode", "all")
	var path := str(wn.call("layer_path"))
	var check := WaterFeatureLayer.new()
	check.load_from(path)
	var ok := bool(check.setting("dry_between_storms")) and str(check.setting("display_mode")) == "all"
	print("bb-dry: saved %s -> dry_between_storms=%s display_mode=%s %s" % [path,
		str(check.setting("dry_between_storms")), str(check.setting("display_mode")),
		"PASS" if ok else "FAIL"])
	return {"ok": ok}

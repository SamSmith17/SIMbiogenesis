extends RefCounted

## What a square metre of greenhouse bed makes in a year at this world's site,
## by the plant node's own model (Monteith LUE on the weather's GHI), with and
## without a protected-season factor. Read-only.
##   tools\harness.ps1 -World w6af22bac295d -RunScript res://tools/diag/greenhouse_yield_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	for i in 60:
		await main.get_tree().process_frame
	var ws: Node = main.get_node_or_null("/root/WeatherService")
	var yr := 2024
	var days := [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	for sun_f in [1.0, 0.8]:
		for protected in [false, true]:
			var tot := 0.0
			var by_m: Array = []
			for m in 12:
				var mt := 0.0
				for d in days[m]:
					for h in 24:
						var ghi := float(ws.call("solar_radiation_wm2", m + 1, d + 1, float(h) + 0.5))
						var par := SolarIrradiance.par_wm2_from_ghi(ghi)
						var season := 0.9 if protected else -1.0
						var r := PlantGrowth.biomass_kg_per_hour(par, 1.0, 2.0, m + 1, 1.0, 1.0, sun_f, season) * 0.6
						mt += r
				by_m.append(snappedf(mt, 0.01))
				tot += mt
			print("ghprobe sun %.1f protected %s: %.2f kg food/m2/yr; by month %s; m2 for 15 kg/day %.0f" % [
				sun_f, str(protected), tot, str(by_m), 15.0 * 366.0 / maxf(tot, 0.001)])
	return {"ok": true}

extends SceneTree

## EnergyRunSankey selftest (offline): a day of sun and loads split by hand
## (direct use, into and out of the battery, its losses read off the recorded
## charge, the charge it started with), a full battery spilling, wind and
## hydro sharing the battery by its share, the not-used share against the
## sky's offer, every node balancing, the loop Sankey input with no returns.
##
## Carries EXPECTED_CHECKS.
##   godot --headless --path . --script core/flow/energy_run_sankey_selftest.gd

const EXPECTED_CHECKS := 16

var _checks := 0
var _fails := 0


func _init() -> void:
	# 1 h steps: two sunny hours charge 1 kWh each at 95 %, two dark hours draw
	# 1 kWh each through a 95 % discharge.
	var e := 0.95
	var soc := PackedFloat32Array([5.0, 5.0 + e, 5.0 + 2.0 * e, 5.0 + 2.0 * e - 1.0 / e,
		5.0 + 2.0 * e - 2.0 / e])
	var f := EnergyRunSankey.flows_from_slices(PackedFloat32Array([2.0, 2.0, 0.0, 0.0]),
		PackedFloat32Array(), PackedFloat32Array([1.0, 1.0, 1.0, 1.0]), soc, 1.0, 10.0, e)
	_ok(_near(f["solar_to_load"], 2.0) and _near(f["load"], 4.0), "sun serves the loads first")
	_ok(_near(f["solar_to_batt"], 2.0) and _near(f["spilled"], 0.0), "the rest charges the battery")
	_ok(_near(f["batt_to_load"], 2.0), "the dark hours draw on the battery")
	var lost := 2.0 * (1.0 - e) + 2.0 * (1.0 / e - 1.0)
	_ok(_near(f["batt_loss"], lost), "battery losses read off the recorded charge (%.4f)" % float(f["batt_loss"]))
	_ok(_near(f["from_store"], 2.0 / e - 2.0 * e) and _near(f["kept"], 0.0), "it ended lower: start charge used")
	_ok(_near(f["not_used"], 6.0) and _near(f["potential"], 10.0), "what the sky offered and was not taken")
	var batt_in := float(f["solar_to_batt"]) + float(f["aux_to_batt"]) + float(f["from_store"])
	var batt_out := float(f["batt_to_load"]) + float(f["batt_loss"]) + float(f["kept"])
	_ok(_near(batt_in, batt_out), "the battery balances")
	_ok(_near(float(f["not_used"]) + float(f["solar"]), float(f["potential"])), "the panels balance")

	# A full battery: nothing goes in, the surplus spills.
	var full := EnergyRunSankey.flows_from_slices(PackedFloat32Array([3.0, 3.0]),
		PackedFloat32Array(), PackedFloat32Array([1.0, 1.0]),
		PackedFloat32Array([16.0, 16.0, 16.0]), 1.0)
	_ok(_near(full["solar_to_batt"], 0.0) and _near(full["spilled"], 4.0) and _near(full["not_used"], 4.0),
		"a full battery spills the surplus")

	# Wind and hydro share the battery with the panels by what they bring.
	var mixed := EnergyRunSankey.flows_from_slices(PackedFloat32Array([3.0]), PackedFloat32Array([1.0]),
		PackedFloat32Array([1.0]), PackedFloat32Array([4.0, 4.0 + 3.0 * e]), 1.0, -1.0, e)
	_ok(_near(mixed["solar_to_load"], 1.0) and _near(mixed["aux_to_load"], 0.0)
		and _near(mixed["solar_to_batt"], 2.0) and _near(mixed["aux_to_batt"], 1.0), "wind and hydro by their share")
	_ok(_near(mixed["kept"], 3.0 * e), "a rise is kept in the battery")

	var inp := EnergyRunSankey.loop_input(f)
	_ok((inp["nodes"] as Array).size() == 3 and (inp["edges"] as Array).size() == 3,
		"three nodes and three flows (no wind or hydro)")
	var lay := LoopSankeyLayout.layout(inp["nodes"], inp["edges"], inp["bin"], inp["bout"], inp["opts"])
	_ok(int(lay.get("returns", 0)) == 0 and (lay["nodes"] as Dictionary).has("battery"),
		"lays out as a one-way Sankey")
	var svg := LoopSankeySvg.render(lay, {"title": "A <day> & night"})
	_ok(svg.begins_with("<svg") and svg.count("<polyline") >= 3 and svg.contains("Battery")
		and svg.contains("&lt;day&gt; &amp; night") and svg.ends_with("</svg>"), "the picture writes as SVG")
	_ok(EnergyRunSankey.loop_input({}).is_empty() and EnergyRunSankey.make_view({}) == null,
		"nothing to draw for an empty run")
	_ok(EnergyRunSankey.summary(f).contains("did work"), "a one-line summary")
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL check count %d != EXPECTED_CHECKS %d" % [_checks, EXPECTED_CHECKS])
	print("ENERGY RUN SANKEY SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _near(a: Variant, b: float) -> bool:
	return absf(float(a) - b) < 1e-4


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL " + what)

extends SceneTree

## Every library preset and builtin recipe closes its mass and elements
## (resource composition plan Phase 3): PresetBalance judges each at its
## listed rates with its own air mode and retained elements, and every row
## must be ok, an estimate, a source, a sink or runtime (rates set live).
## A preset that cannot close with one make-up per kind is listed in
## EXCEPTIONS with the reason; per-tank make-up (Phase 10) is what fixes it.
## Offline:
##   Godot --headless --path . --script core/composition/preset_balance_selftest.gd
## Carries EXPECTED_CHECKS.

const EXCEPTIONS := {
	# Shares the liquid_fertilizer kind with the blackwater digester, but a
	# urine-diverting toilet's brownwater carries about a third of the N:
	# one static make-up per kind cannot show both digestates.
	"Brownwater Digester (3 m³)": "digestate weaker than the shared kind's make-up",
}
const EXPECTED_CHECKS := 7

var _checks := 0
var _fails := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  ok   ", name)
	else:
		_fails += 1
		print("  FAIL ", name, ("  (" + detail + ")") if not detail.is_empty() else "")


func _initialize() -> void:
	var rows := PresetBalance.rows()
	var bad: PackedStringArray = []
	var excepted: PackedStringArray = []
	var by_verdict: Dictionary = {}
	var labels: Dictionary = {}
	for r in rows:
		var rd: Dictionary = r
		var v := str(rd["verdict"])
		by_verdict[v] = int(by_verdict.get(v, 0)) + 1
		labels[str(rd["label"])] = rd
		if PresetBalance.acceptable(v):
			continue
		if EXCEPTIONS.has(str(rd["label"])):
			excepted.append(str(rd["label"]))
			continue
		var mb: Dictionary = rd["mb"]
		bad.append("%s: %s loses %s creates %s unknown %s mass %+.0f %%" % [str(rd["label"]), v,
			mb["loses"], mb["creates"], mb["unknown"], float(mb["mass_rel"]) * 100.0])
	_check("every preset and recipe closes (or is source / sink / runtime)", bad.is_empty(), "\n    ".join(bad))
	var stale: PackedStringArray = []
	for k in EXCEPTIONS.keys():
		if not excepted.has(str(k)):
			stale.append(str(k))
	_check("every listed exception still needs to be one", stale.is_empty(), ", ".join(stale))
	_check("no preset names a kind without a make-up", int(by_verdict.get("unknown", 0)) == 0)
	_check("the audit covers the library (≥ 50 rows)", rows.size() >= 50, "%d rows %s" % [rows.size(), by_verdict])
	# Spot checks: the air side is where the missing elements went.
	var person: Dictionary = labels.get("Population", {})
	var pg: Dictionary = (person.get("mb", {}) as Dictionary).get("air", {})
	_check("people breathe out CO2 and take in O2", float(pg.get("CO2", 0.0)) > 0.0 and float(pg.get("O2", 0.0)) < 0.0, str(pg))
	var bed: Dictionary = labels.get("Greenhouse Grow Bed", {})
	var bg: Dictionary = (bed.get("mb", {}) as Dictionary).get("air", {})
	_check("a grow bed takes CO2 from the air", float(bg.get("CO2", 0.0)) < 0.0, str(bg))
	var sheet: Dictionary = labels.get("recipe: 15 mm Recycled Sheet", {})
	_check("a 15 mm sheet weighs what its 13.5 kg of flake did",
		absf(float((sheet.get("mb", {"mass_rel": 1.0}) as Dictionary)["mass_rel"])) <= 0.05, str(sheet.get("verdict", "")))
	print("verdicts: ", by_verdict)
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("PRESET BALANCE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PRESET BALANCE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)

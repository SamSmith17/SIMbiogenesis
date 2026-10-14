extends SceneTree

## Offline selftest for SimFxRate (core/sim_fx_rate.gd) — the one cosmetic
## clock that fire, crowd figures and placed lights animate on.
##
## Pins the user-facing contract: frozen dead while paused or scrubbing
## backwards, 1:1 at realtime, visibly faster at speed but sublinear and capped
## per system, and the integrated clock CONTINUOUS across a speed change (no
## flame or dance phase may jump when the player changes speed).
##
## Run: Godot.exe.exe --headless --path . --script core/sim_fx_rate_selftest.gd

const EXPECTED_CHECKS := 20

var _fails := 0
var _checks := 0
const RT := SimFxRate.REALTIME_SCALE


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_curve()
	_test_caps()
	_test_paused()
	_test_integration()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("SIM FX RATE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SIM FX RATE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func _test_curve() -> void:
	var cap := 1000.0
	_check("1x runs at 1", _near(SimFxRate.target_rate(RT, cap), 1.0))
	_check("half speed is slow motion", _near(SimFxRate.target_rate(RT * 0.5, cap), 0.5))
	_check("36x -> 6", _near(SimFxRate.target_rate(RT * 36.0, cap), 6.0))
	_check("100x -> 10", _near(SimFxRate.target_rate(RT * 100.0, cap), 10.0))
	var prev := 0.0
	var mono := true
	var sub := true
	for m in [0.25, 1.0, 2.0, 10.0, 60.0, 300.0, 450.0, 1440.0]:
		var r := SimFxRate.target_rate(RT * m, cap)
		if r < prev:
			mono = false
		if m > 1.0 and r >= m:
			sub = false
		prev = r
	_check("monotonic in the clock's multiple", mono)
	_check("never 1:1 above realtime (sublinear)", sub)


func _test_caps() -> void:
	_check("NPC cap holds at 1440x",
			_near(SimFxRate.target_rate(RT * 1440.0, SimFxRate.FX_CAP_NPC), SimFxRate.FX_CAP_NPC))
	_check("fire cap holds at 350x",
			_near(SimFxRate.target_rate(RT * 350.0, SimFxRate.FX_CAP_FIRE), SimFxRate.FX_CAP_FIRE))
	_check("lights cap holds at 350x",
			_near(SimFxRate.target_rate(RT * 350.0, SimFxRate.FX_CAP_LIGHTS), SimFxRate.FX_CAP_LIGHTS))
	_check("a capped system still speeds up below its cap",
			SimFxRate.target_rate(RT * 16.0, SimFxRate.FX_CAP_FIRE) > 1.0)
	_check("NPC cap == the rig's MAX_PLAYBACK_RATE",
			_near(SimFxRate.FX_CAP_NPC, NpcRig.MAX_PLAYBACK_RATE))


func _test_paused() -> void:
	_check("paused -> 0", SimFxRate.target_rate(0.0, 12.0) == 0.0)
	_check("scrubbing backwards -> 0", SimFxRate.target_rate(-RT * 60.0, 12.0) == 0.0)
	_check("the analemma view (INF) -> 0", SimFxRate.target_rate(INF, 12.0) == 0.0)
	_check("NaN -> 0", SimFxRate.target_rate(NAN, 12.0) == 0.0)


func _test_integration() -> void:
	SimFxRate.reset(0.0, 1.0)
	for _i in 60:
		SimFxRate.step(1.0 / 60.0, RT)
	_check("one real second at 1x is one fx second",
			_near(SimFxRate.now(null, SimFxRate.SYS_FIRE), 1.0, 0.01))
	var before := float(SimFxRate.now(null, SimFxRate.SYS_FIRE))
	SimFxRate.step(1.0 / 60.0, 0.0)
	_check("pausing freezes the clock in the SAME frame",
			_near(float(SimFxRate.now(null, SimFxRate.SYS_FIRE)), before, 1e-9))
	_check("and the rate reads 0", float(SimFxRate._rate[SimFxRate.SYS_FIRE]) == 0.0)
	# Speed change: the clock must never step by more than one frame's worth at
	# the cap — i.e. phases ease, they do not teleport.
	var worst := 0.0
	var last := float(SimFxRate._t[SimFxRate.SYS_LIGHTS])
	for i in 120:
		var ts := RT if i < 30 else RT * 1440.0
		SimFxRate.step(1.0 / 60.0, ts)
		var t := float(SimFxRate._t[SimFxRate.SYS_LIGHTS])
		worst = maxf(worst, t - last)
		last = t
	_check("a jump to 1440x eases: no frame advances past the cap",
			worst <= SimFxRate.FX_CAP_LIGHTS / 60.0 + 1e-6, "worst %.4f" % worst)
	_check("and settles at the cap",
			_near(float(SimFxRate._rate[SimFxRate.SYS_LIGHTS]), SimFxRate.FX_CAP_LIGHTS, 0.05))
	SimFxRate.reset(0.0, 1.0)

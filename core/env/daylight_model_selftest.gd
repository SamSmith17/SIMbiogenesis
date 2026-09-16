extends SceneTree

## Offline deterministic selftest for DaylightModel (core/env/daylight_model.gd).
##
## Run: Godot.exe.exe --headless --path . --script core/env/daylight_model_selftest.gd
##
## The thing this file pins that a screenshot cannot: the sunrise is CONTINUOUS.
## Every curve the lighting reads (beam energy, beam colour, skylight, night
## amount, the vegetation signal) is sampled at 0.05° steps across the horizon
## and the largest single step is asserted small — the "lightbulb" regression
## is a step, and a step is a number. Also pins the one-atmosphere contract
## (beam transmittance == SolarIrradiance's clear-sky DNI ratio, so the light
## the player sees and the watts the panels make cannot disagree), the
## measured-CCT colour anchors, the twilight decades, and the zero-below-
## horizon rule (the old ramp lit the ground with the sun 5.7° down).
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS.

const EXPECTED_CHECKS := 73

var _fails := 0
var _checks := 0


func _check( name: String, cond: bool, detail: String = "" ) -> void :
	_checks += 1
	if not cond :
		_fails += 1
		push_error( "FAIL: %s  %s" % [ name, detail ] )


static func _sin( deg: float ) -> float :
	return sin( deg_to_rad( deg ) )


func _initialize() -> void :
	_test_air_mass()
	_test_transmittance_one_atmosphere()
	_test_direct_fraction_continuity()
	_test_direct_color()
	_test_sky_light()
	_test_night_and_vegetation()
	_check( "expected check count", _checks == EXPECTED_CHECKS,
		"ran %d, expected %d — a runtime error aborted a test function, or update EXPECTED_CHECKS" % [ _checks, EXPECTED_CHECKS ] )
	if _fails == 0 :
		print( "DAYLIGHT MODEL SELFTEST PASS  (%d checks)" % _checks )
	else :
		print( "DAYLIGHT MODEL SELFTEST FAIL  (%d of %d checks failed)" % [ _fails, _checks ] )
	quit( 1 if _fails > 0 else 0 )


func _test_air_mass() -> void :
	_check( "air mass zenith = 1", absf( DaylightModel.air_mass( 1.0 ) - 1.0 ) < 1e-6 )
	# Kasten-Young at h = 0: 1 / (0.50572 · 6.07995^-1.6364) = 37.8
	var m0 := DaylightModel.air_mass( 0.0 )
	_check( "air mass horizon ≈ 37.8", m0 > 37.5 and m0 <= 38.0, "%.3f" % m0 )
	var m30 := DaylightModel.air_mass( _sin( 30.0 ) )
	_check( "air mass 30° ≈ 1.99", absf( m30 - 1.994 ) < 0.01, "%.4f" % m30 )
	_check( "air mass below the horizon holds the horizon value (the fit shrinks again below 0°)",
		DaylightModel.air_mass( _sin( -3.0 ) ) == m0 and DaylightModel.air_mass( _sin( -10.0 ) ) == m0 )
	var prev := DaylightModel.air_mass( _sin( 90.0 ) )
	var mono := true
	for i in range( 89, -1, -1 ) :
		var m := DaylightModel.air_mass( _sin( float( i ) ) )
		if m < prev - 1e-9 :
			mono = false
		prev = m
	_check( "air mass rises monotonically toward the horizon", mono )


func _test_transmittance_one_atmosphere() -> void :
	_check( "transmittance zenith = 1", absf( DaylightModel.transmittance( 1.0 ) - 1.0 ) < 1e-9 )
	var t0 := DaylightModel.transmittance( 0.0 )
	_check( "transmittance horizon ≈ 2.5 %", t0 > 0.01 and t0 < 0.05, "%.4f" % t0 )
	var t5 := DaylightModel.transmittance( _sin( 5.0 ) )
	_check( "transmittance 5° ≈ 0.31", absf( t5 - 0.31 ) < 0.03, "%.4f" % t5 )
	var t10 := DaylightModel.transmittance( _sin( 10.0 ) )
	_check( "transmittance 10° ≈ 0.52", absf( t10 - 0.52 ) < 0.03, "%.4f" % t10 )
	var t30 := DaylightModel.transmittance( _sin( 30.0 ) )
	_check( "transmittance 30° ≈ 0.85", absf( t30 - 0.85 ) < 0.03, "%.4f" % t30 )
	var t60 := DaylightModel.transmittance( _sin( 60.0 ) )
	_check( "transmittance 60° ≈ 0.97", absf( t60 - 0.97 ) < 0.02, "%.4f" % t60 )
	# ONE atmosphere: the beam the DirectionalLight carries is the PV model's
	# own clear-sky DNI, normalised. If SolarIrradiance's coefficients move,
	# this fails and DaylightModel._clear_sky_t must follow.
	var dni90 := SolarIrradiance.dni_clear_sky_wm2( 90.0 )
	for h in [ 2.0, 5.0, 10.0, 30.0, 60.0 ] :
		var ratio := SolarIrradiance.dni_clear_sky_wm2( h ) / dni90
		var t := DaylightModel.transmittance( _sin( h ) )
		_check( "one atmosphere: transmittance == DNI ratio at %.0f°" % h,
			absf( ratio - t ) < 1e-6, "dni ratio %.6f vs model %.6f" % [ ratio, t ] )


func _test_direct_fraction_continuity() -> void :
	_check( "no beam at -2°", DaylightModel.direct_fraction( _sin( -2.0 ) ) == 0.0 )
	_check( "no beam at -1°", DaylightModel.direct_fraction( _sin( -1.0 ) ) == 0.0 )
	_check( "no beam at -6° (old ramp lit the ground from -5.7°)", DaylightModel.direct_fraction( _sin( -6.0 ) ) == 0.0 )
	_check( "beam present on the horizon", DaylightModel.direct_fraction( 0.0 ) > 0.015 )
	_check( "beam at 0° is a few percent, not 26 %", DaylightModel.direct_fraction( 0.0 ) < 0.05, "%.4f" % DaylightModel.direct_fraction( 0.0 ) )
	_check( "beam overhead = 1", absf( DaylightModel.direct_fraction( 1.0 ) - 1.0 ) < 1e-9 )
	# Continuity across the whole rise, 0.05° steps from -3° to +90°.
	var prev := DaylightModel.direct_fraction( _sin( -3.0 ) )
	var max_step := 0.0
	var mono := true
	var n := int( 93.0 / 0.05 )
	for i in range( 1, n + 1 ) :
		var h := -3.0 + 0.05 * float( i )
		var f := DaylightModel.direct_fraction( _sin( h ) )
		max_step = maxf( max_step, absf( f - prev ) )
		if f < prev - 1e-9 :
			mono = false
		prev = f
	_check( "beam is monotonic in altitude", mono )
	_check( "beam largest 0.05° step < 1 % of noon (no lightbulb)", max_step < 0.01, "max step %.5f" % max_step )
	# The first 5° of climb is where a sunrise is watched: the beam must be
	# still weak at 1° and clearly growing, not already most of the way up.
	var f1 := DaylightModel.direct_fraction( _sin( 1.0 ) )
	var f2 := DaylightModel.direct_fraction( _sin( 2.0 ) )
	var f5 := DaylightModel.direct_fraction( _sin( 5.0 ) )
	_check( "beam 1° < 10 %", f1 < 0.10, "%.4f" % f1 )
	_check( "beam 2° in 10–20 %", f2 > 0.10 and f2 < 0.20, "%.4f" % f2 )
	_check( "beam 5° in 25–35 %", f5 > 0.25 and f5 < 0.35, "%.4f" % f5 )
	_check( "SUN_ZENITH_GAIN preserves the old midday peak", absf( DaylightModel.SUN_ZENITH_GAIN - 1.3 ) < 1e-9 )


func _test_direct_color() -> void :
	var w := DaylightModel.direct_color( 0.0, 0.0 )
	_check( "warmth 0 = white on the horizon", w.r == 1.0 and w.g == 1.0 and w.b == 1.0 )
	var z := DaylightModel.direct_color( 1.0 )
	_check( "zenith colour is white", z.r > 0.999 and z.g > 0.999 and z.b > 0.999, str( z ) )
	var c0 := DaylightModel.direct_color( 0.0 )
	_check( "horizon: red channel is the max", c0.r == 1.0 )
	_check( "horizon green ≈ 0.44 (≈2100 K)", c0.g > 0.35 and c0.g < 0.55, "%.3f" % c0.g )
	_check( "horizon blue ≈ 0.06", c0.b > 0.03 and c0.b < 0.10, "%.3f" % c0.b )
	var c5 := DaylightModel.direct_color( _sin( 5.0 ) )
	_check( "5°: green ≈ 0.81 (≈3700 K)", c5.g > 0.72 and c5.g < 0.88, "%.3f" % c5.g )
	_check( "5°: blue ≈ 0.48", c5.b > 0.40 and c5.b < 0.58, "%.3f" % c5.b )
	var c10 := DaylightModel.direct_color( _sin( 10.0 ) )
	_check( "10°: blue ≈ 0.70 (≈4600 K)", c10.b > 0.62 and c10.b < 0.78, "%.3f" % c10.b )
	var c30 := DaylightModel.direct_color( _sin( 30.0 ) )
	_check( "30°: near white", c30.g > 0.95 and c30.b > 0.90, str( c30 ) )
	# Blue rises monotonically with altitude and every step is small.
	var prev := DaylightModel.direct_color( _sin( -3.0 ) ).b
	var mono := true
	var max_step := 0.0
	for i in range( 1, int( 93.0 / 0.05 ) + 1 ) :
		var b := DaylightModel.direct_color( _sin( -3.0 + 0.05 * float( i ) ) ).b
		max_step = maxf( max_step, absf( b - prev ) )
		if b < prev - 1e-9 :
			mono = false
		prev = b
	_check( "colour blue channel monotonic in altitude", mono )
	_check( "colour largest 0.05° step < 0.01", max_step < 0.01, "max step %.5f" % max_step )
	var hot := DaylightModel.direct_color( _sin( 5.0 ), 2.0 )
	_check( "warmth 2 is redder than warmth 1", hot.b < c5.b and hot.g < c5.g )
	_check( "warmth is clamped at 0 (negative = white)", DaylightModel.direct_color( 0.0, -1.0 ).b == 1.0 )


func _test_sky_light() -> void :
	_check( "skylight full by 15°", DaylightModel.sky_light( _sin( 15.0 ) ) > 0.999 and DaylightModel.sky_light( _sin( 16.0 ) ) == 1.0 )
	_check( "skylight full at 60°", DaylightModel.sky_light( _sin( 60.0 ) ) == 1.0 )
	_check( "skylight at sunrise = SKY_AT_SUNRISE", absf( DaylightModel.sky_light( 0.0 ) - DaylightModel.SKY_AT_SUNRISE ) < 1e-9 )
	_check( "skylight continuous across the horizon",
		absf( DaylightModel.sky_light( -1e-7 ) - DaylightModel.sky_light( 1e-7 ) ) < 1e-4 )
	var s6 := DaylightModel.sky_light( _sin( -6.0 ) )
	_check( "civil twilight end (-6°) ≈ 0.55·e^-1.5 = 0.123", absf( s6 - 0.55 * exp( -1.5 ) ) < 1e-4, "%.4f" % s6 )
	var s12 := DaylightModel.sky_light( _sin( -12.0 ) )
	_check( "nautical end (-12°) ≈ 0.027", absf( s12 - 0.55 * exp( -3.0 ) ) < 1e-4, "%.4f" % s12 )
	var s18 := DaylightModel.sky_light( _sin( -18.0 ) )
	_check( "astronomical end (-18°) < 0.01", s18 < 0.01 and s18 > 0.0, "%.5f" % s18 )
	_check( "dark by -21°", DaylightModel.sky_light( _sin( -21.0 ) ) == 0.0 )
	_check( "dark at -40°", DaylightModel.sky_light( _sin( -40.0 ) ) == 0.0 )
	# Each degree of depression through civil twilight loses ~22 % — a constant
	# ratio (pure exponential), which is what reads as a steady fade.
	var r1 := DaylightModel.sky_light( _sin( -3.0 ) ) / DaylightModel.sky_light( _sin( -2.0 ) )
	var r2 := DaylightModel.sky_light( _sin( -9.0 ) ) / DaylightModel.sky_light( _sin( -8.0 ) )
	_check( "twilight ratio per degree ≈ e^-0.25", absf( r1 - exp( -0.25 ) ) < 1e-3, "%.4f" % r1 )
	_check( "twilight ratio constant through nautical twilight", absf( r2 - r1 ) < 1e-3, "%.4f vs %.4f" % [ r1, r2 ] )
	# Continuity + monotonicity over -25° … +20° at 0.05°.
	var prev := DaylightModel.sky_light( _sin( -25.0 ) )
	var mono := true
	var max_step := 0.0
	for i in range( 1, int( 45.0 / 0.05 ) + 1 ) :
		var s := DaylightModel.sky_light( _sin( -25.0 + 0.05 * float( i ) ) )
		max_step = maxf( max_step, absf( s - prev ) )
		if s < prev - 1e-9 :
			mono = false
		prev = s
	_check( "skylight monotonic in altitude", mono )
	# Steepest point is the horizon side of twilight: 0.55 · 0.25/° · 0.05° = 0.69 %.
	_check( "skylight largest 0.05° step < 1 %", max_step < 0.01, "max step %.5f" % max_step )
	# twilight_length scales the whole ramp: 2 = twice as slow, cut twice as late.
	var long6 := DaylightModel.sky_light( _sin( -6.0 ), 2.0 )
	_check( "twilight_length 2 is brighter at -6°", long6 > s6 )
	_check( "twilight_length 2 at -12° == length 1 at -6°", absf( DaylightModel.sky_light( _sin( -12.0 ), 2.0 ) - s6 ) < 1e-4 )
	_check( "twilight_length 2 still lit at -30°", DaylightModel.sky_light( _sin( -30.0 ), 2.0 ) > 0.0 )
	_check( "twilight_length 2 dark by -42°", DaylightModel.sky_light( _sin( -42.0 ), 2.0 ) == 0.0 )
	_check( "twilight_length 0.5 is darker at -6°", DaylightModel.sky_light( _sin( -6.0 ), 0.5 ) < s6 )
	_check( "twilight_length does not touch the day side", DaylightModel.sky_light( _sin( 5.0 ), 2.0 ) == DaylightModel.sky_light( _sin( 5.0 ), 1.0 ) )
	_check( "twilight_length floors at 0.05 (no divide by zero)", is_finite( DaylightModel.sky_light( _sin( -6.0 ), 0.0 ) ) )


func _test_night_and_vegetation() -> void :
	_check( "night amount 0 with the sun up", DaylightModel.night_amount( _sin( 10.0 ) ) == 0.0 )
	_check( "night amount 0 on the horizon", DaylightModel.night_amount( 0.0 ) == 0.0 )
	var n6 := DaylightModel.night_amount( _sin( -6.0 ) )
	_check( "night amount at -6° = 1 − e^-1.5", absf( n6 - ( 1.0 - exp( -1.5 ) ) ) < 1e-4, "%.4f" % n6 )
	_check( "night amount 1 at -22°", DaylightModel.night_amount( _sin( -22.0 ) ) == 1.0 )
	_check( "palette 1 on the horizon", DaylightModel.twilight_palette( 0.0 ) == 1.0 )
	_check( "palette + night = 1", absf( DaylightModel.twilight_palette( _sin( -4.0 ) ) + DaylightModel.night_amount( _sin( -4.0 ) ) - 1.0 ) < 1e-9 )
	_check( "vegetation night 1 below the horizon", DaylightModel.vegetation_night( _sin( -1.0 ) ) == 1.0 )
	_check( "vegetation night ≈ 1 on the horizon", DaylightModel.vegetation_night( 0.0 ) > 0.95 )
	_check( "vegetation night ≈ 0 by 6°", DaylightModel.vegetation_night( _sin( 6.0 ) ) < 0.05, "%.3f" % DaylightModel.vegetation_night( _sin( 6.0 ) ) )
	_check( "vegetation night 0 at noon", DaylightModel.vegetation_night( 1.0 ) == 0.0 )
	var prev := DaylightModel.vegetation_night( _sin( -2.0 ) )
	var mono := true
	var max_step := 0.0
	for i in range( 1, int( 12.0 / 0.05 ) + 1 ) :
		var v := DaylightModel.vegetation_night( _sin( -2.0 + 0.05 * float( i ) ) )
		max_step = maxf( max_step, absf( v - prev ) )
		if v > prev + 1e-9 :
			mono = false
		prev = v
	_check( "vegetation night falls monotonically with altitude", mono )
	_check( "vegetation night largest 0.05° step < 3 %", max_step < 0.03, "max step %.4f" % max_step )

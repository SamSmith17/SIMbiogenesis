extends SceneTree

## The first-person ambient bed's MIX RULE (AmbientMix) and its procedural
## sounds (AmbientSynth), offline: wind / rain / stream / birds each a
## monotonic, bounded, continuous function of its input; the gates (night,
## no forest, paused, away from first person, volume 0) each silence exactly
## what they should; the master scales every layer; the loops are seamless,
## bounded, distinguishable by brightness and deterministic; a chirp is short
## and silent at both ends. Carries EXPECTED_CHECKS (a runtime error aborts a
## test function while the suite still prints PASS).
##   godot --headless --path . --script core/audio/ambient_mix_selftest.gd

const EXPECTED_CHECKS := 52

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_wind()
	_test_rain()
	_test_stream()
	_test_birds()
	_test_levels()
	_test_smooth_and_db()
	_test_loops()
	_test_chirp()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL  ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("AMBIENT MIX SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _checks])
	quit(0 if _fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s  %s" % ["PASS" if ok else "FAIL", what])


## Sampled monotonic + bounded + no step larger than `max_step`.
func _curve_ok(f: Callable, lo: float, hi: float, n: int, max_step: float, mono: bool = true) -> bool:
	var prev := float(f.call(lo))
	if prev < 0.0 or prev > 1.0:
		return false
	for i in range(1, n + 1):
		var v := float(f.call(lerpf(lo, hi, float(i) / float(n))))
		if (mono and v < prev - 1e-9) or v < 0.0 or v > 1.0 or absf(v - prev) > max_step:
			return false
		prev = v
	return true


func _test_wind() -> void:
	_check("calm air is silent (0.5 m/s)", AmbientMix.wind_level(0.5) == 0.0)
	_check("a near gale is the full bed (14 m/s)", is_equal_approx(AmbientMix.wind_level(14.0), 1.0))
	_check("a breeze is between (4 m/s: %.2f)" % AmbientMix.wind_level(4.0),
		AmbientMix.wind_level(4.0) > 0.15 and AmbientMix.wind_level(4.0) < 0.6)
	_check("wind is monotonic, bounded and continuous 0..30 m/s",
		_curve_ok(AmbientMix.wind_level, 0.0, 30.0, 300, 0.05))


func _test_rain() -> void:
	_check("no rain is silent", AmbientMix.rain_level(0.0) == 0.0)
	_check("light rain (1 mm/h) is a patter, under the light class ceiling",
		AmbientMix.rain_level(1.0) > 0.0 and AmbientMix.rain_level(1.0) < AmbientMix.RAIN_LIGHT_LEVEL)
	_check("the class boundaries land on their levels (2.5 -> 0.40, 7.6 -> 0.75)",
		is_equal_approx(AmbientMix.rain_level(2.5), 0.4) and is_equal_approx(AmbientMix.rain_level(7.6), 0.75))
	_check("a downpour saturates (30 mm/h and 80 mm/h both 1.0)",
		is_equal_approx(AmbientMix.rain_level(30.0), 1.0) and is_equal_approx(AmbientMix.rain_level(80.0), 1.0))
	_check("rain is monotonic, bounded and continuous 0..40 mm/h",
		_curve_ok(AmbientMix.rain_level, 0.0, 40.0, 400, 0.05))


func _test_stream() -> void:
	_check("no stream (dist -1) is silent", AmbientMix.stream_level(1.0, -1.0) == 0.0)
	_check("a trickle (0.1 m/s) beside you is silent", AmbientMix.stream_level(0.1, 2.0) == 0.0)
	_check("a fast reach at your feet is full", is_equal_approx(AmbientMix.stream_level(1.5, 3.0), 1.0))
	_check("the same reach 30 m off is quieter, 60 m off gone",
		AmbientMix.stream_level(1.5, 30.0) > 0.1 and AmbientMix.stream_level(1.5, 30.0) < 0.5
		and AmbientMix.stream_level(1.5, 60.0) == 0.0)
	_check("distance fall-off is monotonic and continuous 0..70 m",
		_curve_ok(func(d: float) -> float: return 1.0 - AmbientMix.stream_level(1.5, d), 0.0, 70.0, 350, 0.05))
	_check("velocity rise is monotonic and continuous 0..3 m/s",
		_curve_ok(func(v: float) -> float: return AmbientMix.stream_level(v, 2.0), 0.0, 3.0, 300, 0.05))


func _test_birds() -> void:
	var noon := sin(deg_to_rad(60.0))
	var dawn := sin(deg_to_rad(3.0))
	var dusk_deep := sin(deg_to_rad(-15.0))
	_check("night is silent however deep the forest", AmbientMix.bird_level(dusk_deep, 1.0) == 0.0)
	_check("a bare field is silent at noon", AmbientMix.bird_level(noon, 0.0) == 0.0)
	_check("a forest at noon sings (%.2f)" % AmbientMix.bird_level(noon, 1.0), AmbientMix.bird_level(noon, 1.0) > 0.4)
	_check("the dawn chorus is louder than midday (%.2f vs %.2f)" % [AmbientMix.bird_level(dawn, 1.0), AmbientMix.bird_level(noon, 1.0)],
		AmbientMix.bird_level(dawn, 1.0) > AmbientMix.bird_level(noon, 1.0))
	_check("heavy rain hushes them (%.2f -> %.2f)" % [AmbientMix.bird_level(noon, 1.0), AmbientMix.bird_level(noon, 1.0, 20.0)],
		AmbientMix.bird_level(noon, 1.0, 20.0) < 0.4 * AmbientMix.bird_level(noon, 1.0))
	_check("a gale hushes them too", AmbientMix.bird_level(noon, 1.0, 0.0, 20.0) < AmbientMix.bird_level(noon, 1.0))
	_check("birds rise with the sun monotonically through dawn (-20° .. 3°)",
		_curve_ok(func(a: float) -> float: return AmbientMix.bird_level(sin(deg_to_rad(a)), 1.0), -20.0, 3.0, 460, 0.05))
	_check("…and stay continuous on through the midday hush (-20° .. 60°)",
		_curve_ok(func(a: float) -> float: return AmbientMix.bird_level(sin(deg_to_rad(a)), 1.0), -20.0, 60.0, 1600, 0.05, false))
	_check("a lone tree is not a forest; 30 trees in 30 m is one",
		AmbientMix.forest_density(1) < 0.05 and AmbientMix.forest_density(80) == 1.0)


func _test_levels() -> void:
	var base := {"wind_ms": 8.0, "rain_mmh": 5.0, "stream_v_ms": 1.2, "stream_dist_m": 4.0,
		"sun_sin_alt": 0.7, "forest": 0.8, "volume": 1.0, "paused": false, "first_person": true}
	var l := AmbientMix.levels(base)
	_check("every layer sounds in a windy rainy forest by a stream",
		float(l["wind"]) > 0.3 and float(l["rain"]) > 0.4 and float(l["stream"]) > 0.5 and float(l["birds"]) > 0.0)
	var half := base.duplicate()
	half["volume"] = 0.5
	var lh := AmbientMix.levels(half)
	var scaled := true
	for k in ["wind", "rain", "stream", "birds"]:
		scaled = scaled and is_equal_approx(float(lh[k]), 0.5 * float(l[k]))
	_check("the master scales every layer alike", scaled and is_equal_approx(float(lh["master"]), 0.5))
	var paused := base.duplicate()
	paused["paused"] = true
	var lp := AmbientMix.levels(paused)
	_check("paused = silence, chirps included",
		float(lp["wind"]) == 0.0 and float(lp["rain"]) == 0.0 and float(lp["stream"]) == 0.0
		and float(lp["birds"]) == 0.0 and float(lp["chirps_per_s"]) == 0.0)
	var graph := base.duplicate()
	graph["first_person"] = false
	var lg := AmbientMix.levels(graph)
	_check("away from first person = silence", float(lg["master"]) == 0.0 and float(lg["wind"]) == 0.0)
	var off := base.duplicate()
	off["volume"] = 0.0
	_check("volume 0 = silence", float(AmbientMix.levels(off)["master"]) == 0.0)
	_check("the chirp rate follows the birds level (%.2f/s)" % float(l["chirps_per_s"]),
		is_equal_approx(float(l["chirps_per_s"]), float(l["birds"]) * AmbientMix.BIRD_CHIRPS_PER_S))
	_check("missing inputs are the quiet default (no error, every layer 0 at night in a field)",
		float(AmbientMix.levels({})["wind"]) == 0.0 and float(AmbientMix.levels({})["birds"]) == 0.0)
	_check("the rule is deterministic", AmbientMix.levels(base) == l)


func _test_smooth_and_db() -> void:
	var v := 0.0
	for _i in 60:
		v = AmbientMix.smooth(v, 1.0, 1.0 / 60.0)
	_check("one second of easing lands near but not on the target (%.3f)" % v, v > 0.75 and v < 0.9)
	_check("smooth never overshoots", AmbientMix.smooth(0.0, 1.0, 100.0) <= 1.0 and AmbientMix.smooth(1.0, 0.0, 100.0) >= 0.0)
	_check("a dt of 0 leaves the value alone", AmbientMix.smooth(0.3, 1.0, 0.0) == 1.0 or AmbientMix.smooth(0.3, 1.0, 0.0) == 0.3)
	_check("gain 1 is 0 dB, gain 0 is the -80 dB floor, half is about -6 dB",
		is_equal_approx(AmbientMix.gain_to_db(1.0), 0.0) and AmbientMix.gain_to_db(0.0) == -80.0
		and absf(AmbientMix.gain_to_db(0.5) + 6.02) < 0.1)


func _test_loops() -> void:
	var wind := AmbientSynth.wind_loop()
	var rain := AmbientSynth.rain_loop()
	var stream := AmbientSynth.stream_loop()
	var expect_n := int(AmbientSynth.LOOP_S * AmbientSynth.RATE) - int(AmbientSynth.XFADE_S * AmbientSynth.RATE)
	_check("each loop is LOOP_S minus the cross-fade long (%d samples)" % wind.size(),
		wind.size() == expect_n and rain.size() == expect_n and stream.size() == expect_n)
	_check("every loop peaks at PEAK, never clips",
		absf(AmbientSynth.peak_abs(wind) - AmbientSynth.PEAK) < 1e-3 and AmbientSynth.peak_abs(rain) <= 1.0
		and absf(AmbientSynth.peak_abs(stream) - AmbientSynth.PEAK) < 1e-3)
	_check("every loop has body (RMS > 0.05)",
		AmbientSynth.rms(wind) > 0.05 and AmbientSynth.rms(rain) > 0.05 and AmbientSynth.rms(stream) > 0.05)
	_check("the loop points are seamless (join step <= the largest step inside: %.2f / %.2f / %.2f)"
		% [AmbientSynth.seam_ratio(wind), AmbientSynth.seam_ratio(rain), AmbientSynth.seam_ratio(stream)],
		AmbientSynth.seam_ratio(wind) <= 1.0 and AmbientSynth.seam_ratio(rain) <= 1.0 and AmbientSynth.seam_ratio(stream) <= 1.0)
	var bw := AmbientSynth.brightness(wind)
	var br := AmbientSynth.brightness(rain)
	var bs := AmbientSynth.brightness(stream)
	_check("wind is the darkest bed, rain the brightest, the stream between (%.2f < %.2f < %.2f)" % [bw, bs, br],
		bw < bs and bs < br)
	_check("a loop is deterministic (same seed, same samples)", AmbientSynth.wind_loop() == wind)
	_check("a different seed is a different loop", AmbientSynth.wind_loop(99) != wind)
	var seam := PackedFloat32Array([0.0, 0.5, 1.0, 0.5, 0.0, -0.5, -1.0, -0.5])
	var hard := PackedFloat32Array([0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1])
	_check("seam_ratio reads a continuous loop as <= 1 and a sawtooth's join as > 1",
		AmbientSynth.seam_ratio(seam) <= 1.0 and AmbientSynth.seam_ratio(hard) > 1.0)
	var fixed := AmbientSynth.make_seamless(hard, 4)
	_check("make_seamless shortens by the fade and closes the join (%.2f)" % AmbientSynth.seam_ratio(fixed),
		fixed.size() == hard.size() - 4 and AmbientSynth.seam_ratio(fixed) <= 1.0)
	var wav := AmbientSynth.to_wav(wind, true)
	_check("to_wav: 16-bit mono at the rate, looped over the whole buffer",
		wav.format == AudioStreamWAV.FORMAT_16_BITS and wav.mix_rate == AmbientSynth.RATE and not wav.stereo
		and wav.loop_mode == AudioStreamWAV.LOOP_FORWARD and wav.loop_end == wind.size()
		and wav.data.size() == wind.size() * 2)
	_check("to_wav encodes the peak sample (±0.85 -> ±27852)",
		absi(wav.data.decode_s16(_argmax(wind) * 2)) == int(AmbientSynth.PEAK * 32767.0))


func _argmax(a: PackedFloat32Array) -> int:
	var best := 0
	for i in a.size():
		if absf(a[i]) > absf(a[best]):
			best = i
	return best


func _test_chirp() -> void:
	var c := AmbientSynth.chirp(101)
	var secs := float(c.size()) / float(AmbientSynth.RATE)
	_check("a chirp is short (%.2f s, 2-4 notes)" % secs, secs > 0.15 and secs < 0.9)
	_check("a chirp starts and ends in silence", absf(c[0]) < 1e-6 and absf(c[c.size() - 1]) < 1e-6)
	_check("a chirp never clips", AmbientSynth.peak_abs(c) <= 0.8 + 1e-6 and AmbientSynth.peak_abs(c) > 0.3)
	_check("chirps differ by seed and repeat by seed",
		AmbientSynth.chirp(102) != c and AmbientSynth.chirp(101) == c)
	var one := AmbientSynth.to_wav(c, false)
	_check("a chirp's WAV is a one-shot", one.loop_mode == AudioStreamWAV.LOOP_DISABLED)

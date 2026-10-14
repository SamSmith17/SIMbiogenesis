extends SceneTree

## THE BEAT selftest — BeatGrid (the virtual set), BeatTracker (live analysis
## of a real track), StageBeat (what reaches a spot, the light levels, the
## crowd shader's mirror constants) and, last, the REAL audio path: a
## generated kick track played through StageMusic's own analysis bus and
## tracker for ~22 s of real time (the headless Dummy audio driver mixes, so
## this runs anywhere — run it --windowed for a real driver's timing: 128.1
## BPM, the drop within 20 ms). Carries EXPECTED_CHECKS (a runtime error aborts a test
## function while the suite still prints PASS).
##   godot --headless --path . --script core/population/stage_beat_selftest.gd

const EXPECTED_CHECKS := 36

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run()


func _check(what: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s  %s" % ["PASS" if ok else "FAIL", what])


func _run() -> void:
	# The root is not inside the tree during _initialize: nothing can play yet.
	await process_frame
	_test_virtual_set()
	_test_tracker()
	_test_tracker_174()
	_test_stage_beat()
	_test_light_level()
	_test_shader_mirror()
	await _test_live_audio()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL  ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	print("STAGE BEAT SELFTEST %s  (%d checks)" % ["PASS" if _fails == 0 else "FAIL", _checks])
	quit(0 if _fails == 0 else 1)


# --- the virtual set -----------------------------------------------------------

func _test_virtual_set() -> void:
	var seed := 0.55   # -> 128 BPM
	var bpm := BeatGrid.bpm_for(seed)
	var spb := 60.0 / bpm
	_check("a venue's tempo comes from the set list (%.0f BPM)" % bpm, bpm in BeatGrid.BPMS)
	var s0 := BeatGrid.state(0.0, seed)
	_check("a set opens mid-groove, the first drop about half a minute away (%.1f s)" % float(s0["until_drop"]),
		absf(float(s0["until_drop"]) - 64.0 * spb) < 1e-6 and float(s0["energy"]) == BeatGrid.INTRO_ENERGY)
	var t_drop := 64.0 * spb
	var at_drop := BeatGrid.state(t_drop + 1e-6, seed)
	_check("the drop: pulse 1, since 0, the next one a whole phrase away",
		float(at_drop["drop_pulse"]) > 0.99 and float(at_drop["since_drop"]) < 1e-3
		and absf(float(at_drop["until_drop"]) - BeatGrid.PHRASE_BEATS * spb) < 1e-3)
	var brk := BeatGrid.state(t_drop + 100.0 * spb, seed)
	_check("beat 100 of a phrase is the breakdown: low energy, no build yet",
		bool(brk["breakdown"]) and float(brk["energy"]) < 0.5 and float(brk["build"]) == 0.0)
	var b1 := BeatGrid.state(t_drop + 116.0 * spb, seed)
	var b2 := BeatGrid.state(t_drop + 124.0 * spb, seed)
	_check("the build rises through the last bars (%.2f -> %.2f)" % [float(b1["build"]), float(b2["build"])],
		float(b1["build"]) > 0.2 and float(b2["build"]) > float(b1["build"]) and float(b2["energy"]) > float(b1["energy"]))
	var cont := true
	var prev := BeatGrid.state(0.0, seed)
	for i in range(1, 600):
		var s := BeatGrid.state(float(i) * 0.25, seed)
		cont = cont and float(s["beat"]) > float(prev["beat"]) \
			and absf(float(s["beat"]) - float(prev["beat"]) - 0.25 / spb) < 1e-6
		prev = s
	_check("the beat never jumps (2.5 min sampled)", cont)


# --- live tracking -----------------------------------------------------------

## A synthetic set's bass band: kicks every beat from `t_first`, none in
## [break_a, break_b), the drop's kick at break_b. Shaped like the spectrum
## analyzer's reading of a real kick (fast attack, ~90 ms decay).
static func _bass(t: float, bpm: float, t_first: float, break_a: float, break_b: float) -> float:
	var spb := 60.0 / bpm
	var v := 0.015
	var k0 := maxi(int(floor((t - t_first) / spb)) - 4, 0)
	for k in range(k0, k0 + 6):
		var tk := t_first + float(k) * spb
		if tk > t:
			break
		if tk >= break_a and tk < break_b - 1e-6:
			continue
		v += 0.42 * exp(-(t - tk) / 0.09)
	return v


func _feed(tr: BeatTracker, t_end: float, bpm: float, t_first: float, ba: float, bb: float) -> void:
	var t := 0.0
	while t <= t_end:
		tr.feed(t, _bass(t, bpm, t_first, ba, bb))
		t += 1.0 / 60.0


func _test_tracker() -> void:
	var bpm := 126.0
	var spb := 60.0 / bpm
	var t_first := 0.13
	var ba := t_first + 32.0 * spb
	var bb := t_first + 48.0 * spb   # the drop (a kick)
	var tr := BeatTracker.new()
	tr.lookahead = 5.0
	_feed(tr, bb - 4.0, bpm, t_first, ba, bb)
	_check("the tempo is found (%.2f BPM, want 126)" % tr.bpm(), tr.synced() and absf(tr.bpm() - 126.0) < 1.0)
	var phase_ok := true
	for k in range(14, 30):
		var bk := tr.beat_at(t_first + float(k) * spb)
		phase_ok = phase_ok and absf(bk - roundf(bk)) < 0.08
	_check("the beat lands on the kicks (every kick within 0.08 of a whole beat)", phase_ok)
	var q_break := tr.query(ba + 5.0 * spb)
	_check("a breakdown is a breakdown (energy %.2f)" % float(q_break["energy"]),
		bool(q_break["breakdown"]) and float(q_break["energy"]) < 0.5)
	_check("no drop is known before the analysis reaches it", float(q_break["until_drop"]) == INF)
	# The analysis reaches the drop; the HEARD clock is lookahead behind.
	_feed_from(tr, bb - 4.0, bb + 1.0, bpm, t_first, ba, bb)
	_check("the drop is found within a beat of the real one",
		tr.drops.size() == 1 and absf(tr.drops[0] - bb) < 0.5 * spb)
	var heard := tr.query(bb - 3.0)
	_check("...and known 3 s BEFORE it is heard (until %.2f s, build %.2f)" % [float(heard["until_drop"]), float(heard["build"])],
		absf(float(heard["until_drop"]) - 3.0) < 0.5 * spb and float(heard["build"]) > 0.3)
	var after := tr.query(bb + 0.2)
	_check("just after the drop: the pulse is up and the breakdown is over",
		float(after["drop_pulse"]) > 0.8 and not bool(after["breakdown"]))
	_feed_from(tr, bb + 1.0, bb + 12.0, bpm, t_first, ba, bb)
	var bdrop := tr.beat_at(bb + 8.0 * spb)
	_check("the beat survives the breakdown (a kick after the drop on a whole beat, %.3f)" % bdrop,
		tr.synced() and absf(bdrop - roundf(bdrop)) < 0.1)


func _feed_from(tr: BeatTracker, t0: float, t1: float, bpm: float, t_first: float, ba: float, bb: float) -> void:
	var t := t0
	while t <= t1:
		tr.feed(t, _bass(t, bpm, t_first, ba, bb))
		t += 1.0 / 60.0


func _test_tracker_174() -> void:
	var tr := BeatTracker.new()
	_feed(tr, 14.0, 174.0, 0.05, 999.0, 999.0)
	_check("drum & bass tempo is not halved (%.1f BPM)" % tr.bpm(), absf(tr.bpm() - 174.0) < 2.0)
	var tr2 := BeatTracker.new()
	_feed(tr2, 14.0, 92.0, 0.05, 999.0, 999.0)
	_check("a slow groove is not doubled (%.1f BPM)" % tr2.bpm(), absf(tr2.bpm() - 92.0) < 1.5)


# --- StageBeat -----------------------------------------------------------------

func _test_stage_beat() -> void:
	var v := [
		{"sid": "a", "pos": Vector2(0, 0), "radius": 180.0, "bpm": 120.0, "beat": 10.0, "stamp_us": 0,
			"running": true, "energy": 1.0, "until_drop": 3.0, "since_drop": INF, "drop_pulse": 0.0},
		{"sid": "b", "pos": Vector2(300, 0), "radius": 180.0, "bpm": 140.0, "beat": 0.0, "stamp_us": 0,
			"running": true, "energy": 1.0, "until_drop": INF, "since_drop": INF, "drop_pulse": 0.0},
	]
	var near := StageBeat.nearest(v, Vector2(20, 0), 0)
	_check("the nearest stage in earshot is the one you hear", str(near.get("sid", "")) == "a")
	_check("out of earshot of both: silence", StageBeat.nearest(v, Vector2(150, 900), 0).is_empty())
	var later := StageBeat.nearest(v, Vector2(20, 0), 1_000_000)
	_check("one second later the beat has moved on two beats at 120 BPM and the drop is a second closer",
		absf(float(later["beat"]) - 12.0) < 1e-6 and absf(float(later["until_drop"]) - 2.0) < 1e-6)
	var paused := (v[0] as Dictionary).duplicate()
	paused["running"] = false
	_check("paused music does not move", absf(float(StageBeat.extrapolate(paused, 5_000_000)["beat"]) - 10.0) < 1e-9)
	_check("anticipation: nothing outside the run-up, rising through it",
		StageBeat.anticipation({"until_drop": 9.0}) == 0.0 and StageBeat.anticipation({"until_drop": INF}) == 0.0
		and StageBeat.anticipation({"until_drop": 1.0}) > StageBeat.anticipation({"until_drop": 3.0}))


func _test_light_level() -> void:
	_check("no music: a reactive light is just itself", StageBeat.light_level({}, 1.0) == 1.0)
	var on := StageBeat.light_level({"beat": 8.0, "energy": 1.0}, 1.0)
	var off := StageBeat.light_level({"beat": 8.5, "energy": 1.0}, 1.0)
	_check("it pumps: brighter on the beat than between beats (%.2f vs %.2f)" % [on, off], on > off * 2.0)
	_check("depth 0 = no reaction", StageBeat.light_level({"beat": 8.0}, 0.0) == 1.0)
	var brk := StageBeat.light_level({"beat": 8.0, "energy": 0.3}, 1.0)
	_check("a breakdown dims it", brk < on)
	var drop := StageBeat.light_level({"beat": 8.5, "energy": 1.0, "drop_pulse": 1.0}, 1.0)
	_check("the drop flashes it", drop > on)
	# Build: the kick rolls in 8ths then 16ths — half a beat is a kick again.
	var roll := StageBeat.light_level({"beat": 8.5, "energy": 1.0, "build": 0.6}, 1.0)
	_check("through a build the pulse rolls faster (a kick on the half beat)", roll > off * 2.0)
	_check("the effect clock moves with the music", StageBeat.light_time({"beat": 10.0}) > StageBeat.light_time({"beat": 2.0}))


func _test_shader_mirror() -> void:
	var src := FileAccess.get_file_as_string("res://core/population/crowd_figure.gdshader")
	var re := RegEx.create_from_string("const float MUSIC_ANTICIPATE_S = ([0-9.]+);")
	var m := re.search(src)
	_check("crowd shader's run-up window == StageBeat.ANTICIPATE_S",
		m != null and absf(float(m.get_string(1)) - StageBeat.ANTICIPATE_S) < 1e-6)
	_check("the shader declares every slot StageBeat pushes",
		src.contains("global uniform vec4 music_pos%d;" % (StageBeat.SHADER_SLOTS - 1))
		and src.contains("global uniform vec4 music_beat%d;" % (StageBeat.SHADER_SLOTS - 1)))
	var proj := FileAccess.get_file_as_string("res://project.godot")
	_check("...and project.godot declares them (globals are never added at runtime)",
		proj.contains("music_pos%d={" % (StageBeat.SHADER_SLOTS - 1)) and proj.contains("music_beat0={"))


# --- the real audio path -------------------------------------------------------

## A 30 s mono track at 128 BPM: kicks (55 Hz thump) from 0.1 s, a breakdown
## (no kick, a quiet high pad) from beat 24, the DROP on beat 36.
static func _track() -> AudioStreamWAV:
	var rate := 22050
	var secs := 30.0
	var n := int(rate * secs)
	var spb := 60.0 / 128.0
	var data := PackedByteArray()
	data.resize(n * 2)
	var t_first := 0.1
	var ba := t_first + 24.0 * spb
	var bb := t_first + 36.0 * spb
	for i in n:
		var t := float(i) / rate
		var k := floorf((t - t_first) / spb)
		var tk := t_first + k * spb
		var s := 0.0
		if t >= t_first and not (tk >= ba and tk < bb - 1e-6):
			var dt := t - tk
			s += sin(TAU * 55.0 * dt) * exp(-dt * 16.0) * 0.85
		s += sin(TAU * 3200.0 * t) * 0.03
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


func _test_live_audio() -> void:
	var sm := StageMusic.new()
	root.add_child(sm)
	var p := AudioStreamPlayer3D.new()
	p.stream = _track()
	sm.add_child(p)
	var e := {"player": p, "file": "_selftest", "on": true, "gain": 0.0, "vt": 0.0, "ana": {},
		"pos": Vector2.ZERO, "stype": "stage", "seed": 0.5, "sid": "selftest"}
	sm.set_process(false)   # no registry here: drive the analysis by hand
	sm._players["selftest"] = e
	sm.call("_start_analysis", e)
	var a: Dictionary = e["ana"]
	_check("a track gets an analysis slot on its own silent bus",
		not a.is_empty() and AudioServer.get_bus_volume_db(int(a["bus"])) <= -79.0)
	if a.is_empty():
		for _i in 4:
			_check("(skipped: no analysis slot)", false)
		return
	var tr: BeatTracker = a["tracker"]
	var t0 := Time.get_ticks_msec()
	var until_seen := INF
	var spb := 60.0 / 128.0
	var drop_track := 0.1 + 36.0 * spb
	while Time.get_ticks_msec() - t0 < 22500:
		await process_frame
		sm.call("_tick_analysis", 1.0 / 60.0, false)
		# What the crowd would see right now (the HEARD time).
		var heard := float(a["mono"]) - StageMusic.LOOKAHEAD_S
		if heard > drop_track - 4.0 and heard < drop_track - 1.0 and until_seen == INF:
			var q := tr.query(heard)
			if float(q["until_drop"]) < INF:
				until_seen = float(q["until_drop"]) - (drop_track - heard)
	print("  live: bpm %.2f, drops %s (true %.3f), early-warning error %.3f s" % [tr.bpm(),
		str(tr.drops), drop_track, until_seen])
	_check("the real audio path finds the tempo (%.2f BPM, want 128)" % tr.bpm(), absf(tr.bpm() - 128.0) < 1.5)
	_check("...finds the drop on the track's own clock",
		tr.drops.size() >= 1 and absf(tr.drops[0] - drop_track) < 0.25)
	_check("...and knows it before it is heard (error %.3f s)" % until_seen, absf(until_seen) < 0.25)
	var bk := tr.beat_at(0.1 + 40.0 * spb)
	# 0.25: the headless Dummy driver's timing is skewed ~0.6 % (it reads 128.8
	# BPM and drifts ~0.18 beat here); on a real driver this lands within
	# ~0.05 (run the suite --windowed for the precise numbers).
	_check("...with the beat on the kicks after the drop (%.3f)" % bk, tr.synced() and absf(bk - roundf(bk)) < 0.25)
	sm.call("_stop_analysis", e)
	sm.queue_free()

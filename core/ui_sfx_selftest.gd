extends SceneTree

## Offline checks for the synthesized UI feedback sounds (core/ui_sfx.gd).
## Mirrors graph_electrical_selftest's destroy-FX envelope test: the generators
## are pure statics over a fixed seed, so their shape can be pinned headlessly
## with no audio server. Beyond format/envelope this asserts the things that
## make each tier legible — the success chime RISES, the womp-womp FALLS, and
## the per-wire click is quiet and very short.

const RATE := UiSfx.SAMPLE_RATE


func _initialize() -> void:
	var fails := 0
	fails += _test_all_tiers_wellformed()
	fails += _test_determinism()
	fails += _test_success_rises()
	fails += _test_warn_descends()
	fails += _test_connect_is_short_and_quiet()
	fails += _test_danger_matches_graph_boom()
	if fails == 0:
		print("UI SFX SELFTEST PASS  (6 checks)")
		quit(0)
	else:
		print("UI SFX SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _samples(stream: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var data := stream.data
	var n := int(data.size() / 2)
	out.resize(n)
	for i in n:
		out[i] = float(data.decode_s16(i * 2)) / 32767.0
	return out


func _peak(s: PackedFloat32Array, from_i: int, to_i: int) -> float:
	var p := 0.0
	for i in range(maxi(from_i, 0), mini(to_i, s.size())):
		p = maxf(p, absf(s[i]))
	return p


## Zero crossings per second ≈ 2×dominant frequency for a roughly periodic
## signal — enough to tell "this half is higher pitched than that half".
func _zcr_hz(s: PackedFloat32Array, from_i: int, to_i: int) -> float:
	var lo := maxi(from_i, 1)
	var hi := mini(to_i, s.size())
	if hi - lo < 2:
		return 0.0
	var crossings := 0
	for i in range(lo, hi):
		if (s[i - 1] < 0.0 and s[i] >= 0.0) or (s[i - 1] > 0.0 and s[i] <= 0.0):
			crossings += 1
	var secs := float(hi - lo) / float(RATE)
	return (float(crossings) * 0.5) / maxf(secs, 1e-6)


func _test_all_tiers_wellformed() -> int:
	for kind in [UiSfx.SUCCESS, UiSfx.CONNECT, UiSfx.WARN, UiSfx.DANGER, UiSfx.FANFARE]:
		var stream: AudioStreamWAV = UiSfx.build_stream(str(kind))
		if stream == null:
			push_error("no stream built for tier '%s'" % str(kind))
			return 1
		if stream.format != AudioStreamWAV.FORMAT_16_BITS:
			push_error("'%s' must be 16-bit" % str(kind))
			return 1
		if stream.stereo:
			push_error("'%s' must be mono" % str(kind))
			return 1
		if stream.data.size() % 2 != 0 or stream.data.size() < 512:
			push_error("'%s' has a suspicious buffer size %d" % [str(kind), stream.data.size()])
			return 1
		var s := _samples(stream)
		# Audible at the attack and quieter by the end — i.e. it is an envelope,
		# not a drone and not silence.
		var head := _peak(s, 0, int(s.size() * 0.35))
		var tail := _peak(s, int(s.size() * 0.9), s.size())
		if head < 0.05:
			push_error("'%s' is effectively silent (head peak %.3f)" % [str(kind), head])
			return 1
		if tail >= head:
			push_error("'%s' does not decay (head %.3f, tail %.3f)" % [str(kind), head, tail])
			return 1
	if UiSfx.build_stream("no_such_tier") != null:
		push_error("unknown tier should yield no stream")
		return 1
	return 0


## Fixed seeds / pure math: two builds must be byte-identical, or the sounds
## would drift between sessions and the pins here would be meaningless.
func _test_determinism() -> int:
	for kind in [UiSfx.SUCCESS, UiSfx.WARN, UiSfx.DANGER, UiSfx.FANFARE]:
		var a: AudioStreamWAV = UiSfx.build_stream(str(kind))
		var b: AudioStreamWAV = UiSfx.build_stream(str(kind))
		if a.data != b.data:
			push_error("'%s' is not deterministic across builds" % str(kind))
			return 1
	return 0


## Success is two notes a fifth apart going UP — that shape is what reads as
## "yes" rather than "uh oh".
func _test_success_rises() -> int:
	var s := _samples(UiSfx.build_success_stream())
	var first := _zcr_hz(s, int(RATE * 0.01), int(RATE * 0.07))
	var second := _zcr_hz(s, int(RATE * 0.11), int(RATE * 0.17))
	if second <= first * 1.15:
		push_error("success chime should rise in pitch (%.0f Hz → %.0f Hz)" % [first, second])
		return 1
	return 0


## The womp-womp must FALL — both within the first note and from the first note
## to the second. A rising version would read as a success cue.
func _test_warn_descends() -> int:
	var s := _samples(UiSfx.build_warn_stream())
	var n1_early := _zcr_hz(s, int(RATE * 0.02), int(RATE * 0.10))
	var n1_late := _zcr_hz(s, int(RATE * 0.16), int(RATE * 0.24))
	var n2 := _zcr_hz(s, int(RATE * 0.34), int(RATE * 0.50))
	if n1_late >= n1_early:
		push_error("first womp should bend down (%.0f → %.0f Hz)" % [n1_early, n1_late])
		return 1
	if n2 >= n1_early:
		push_error("second womp should sit below the first (%.0f vs %.0f Hz)" % [n2, n1_early])
		return 1
	# Two distinct notes: there is a gap between them.
	var gap := _peak(s, int(RATE * 0.275), int(RATE * 0.295))
	var body := _peak(s, int(RATE * 0.05), int(RATE * 0.15))
	if gap >= body * 0.6:
		push_error("womps should be separated by a gap (gap %.3f vs body %.3f)" % [gap, body])
		return 1
	return 0


## Fires on every wire, so it must stay short and well under the other tiers.
func _test_connect_is_short_and_quiet() -> int:
	var stream := UiSfx.build_connect_stream()
	var secs := float(stream.data.size() / 2) / float(RATE)
	if secs > 0.12:
		push_error("connect tick too long (%.3f s) — it fires on every wire" % secs)
		return 1
	if float(UiSfx.TIER_GAIN_DB[UiSfx.CONNECT]) >= float(UiSfx.TIER_GAIN_DB[UiSfx.SUCCESS]) - 6.0:
		push_error("connect tick must be mixed well below the success chime")
		return 1
	return 0


## GraphCanvas.build_boom_stream now delegates here; the destroy FX and the
## DANGER tier must stay literally the same sound (graph_electrical_selftest
## still pins the envelope through the GraphCanvas entry point).
func _test_danger_matches_graph_boom() -> int:
	var GraphCanvasScript := load("res://system_graph/graph_canvas.gd") as GDScript
	if GraphCanvasScript == null:
		push_error("could not load graph_canvas.gd")
		return 1
	var via_canvas: AudioStreamWAV = GraphCanvasScript.build_boom_stream()
	var direct := UiSfx.build_danger_stream(
		int(GraphCanvasScript.BOOM_SAMPLE_RATE), float(GraphCanvasScript.BOOM_SECONDS))
	if via_canvas == null or direct == null:
		push_error("boom stream build returned null (static call did not resolve)")
		return 1
	if via_canvas.data.is_empty():
		push_error("boom stream is empty")
		return 1
	if via_canvas.data != direct.data:
		push_error("destroy boom and DANGER tier have diverged")
		return 1
	if via_canvas.mix_rate != GraphCanvasScript.BOOM_SAMPLE_RATE:
		push_error("boom mix rate changed")
		return 1
	return 0

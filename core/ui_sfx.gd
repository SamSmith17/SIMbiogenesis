class_name UiSfx
extends Node

## Tiered UI feedback sounds, synthesized at runtime rather than shipped as
## assets — same rationale as GraphCanvas.build_boom_stream(): no binary in the
## repo and nothing to add to the credits ledger. Every generator is a pure
## static function over a fixed seed, so the sounds are byte-identical run to
## run and can be pinned headlessly (core/ui_sfx_selftest.gd).
##
## Registered as the autoload **UiSound** (deliberately NOT "UiSfx" — an
## autoload may not share a name with a global class). Resolve it defensively,
## never as a bare identifier, or offline selftests that preload a caller break
## with "Identifier not found":
##     var sfx := get_node_or_null("/root/UiSound")
##     if sfx != null: sfx.call("play_ui", UiSfx.SUCCESS)
##
## Tiers (what the player is being told):
##   SUCCESS  — you did the right thing; an objective advanced
##   CONNECT  — a wire landed (quiet, rate-limited; per-action confirmation)
##   WARN     — allowed, but wrong or wasteful; nothing was destroyed
##   DANGER   — you broke something; pairs with the destroy FX
##   FANFARE  — you earned something (level complete / component unlocked)

const SUCCESS := "success"
const CONNECT := "connect"
const WARN := "warn"
const DANGER := "danger"
const FANFARE := "fanfare"

const SAMPLE_RATE := 22050
const BUS_NAME := "UI"
const PREFS_PATH := "user://audio_prefs.cfg"
## Voices, so a warn chirp landing on top of a boom doesn't cut it off (the
## graph's single cached boom player had exactly that limitation).
const VOICE_COUNT := 4
## Per-tier trim so the quiet tiers stay in the background.
const TIER_GAIN_DB := {
	SUCCESS: -8.0,
	CONNECT: -20.0,
	WARN: -8.0,
	DANGER: -6.0,
	FANFARE: -6.0,
}

var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _muted: bool = false
var _volume_db: float = 0.0
var _last_played_ms: Dictionary = {}


# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # UI feedback must survive pause
	_load_prefs()


## Play a tier. `min_gap_ms` rate-limits a tier against itself — the per-wire
## CONNECT click uses it so rapid wiring can't machine-gun.
func play_ui(kind: String, min_gap_ms: int = 0) -> void:
	if _muted or not is_inside_tree():
		return
	if DisplayServer.get_name() == "headless":
		return
	if min_gap_ms > 0:
		var now := Time.get_ticks_msec()
		# Sentinel is "long enough ago that the first play always passes".
		var last: int = int(_last_played_ms.get(kind, -1_000_000))
		if now - last < min_gap_ms:
			return
		_last_played_ms[kind] = now
	var stream := _stream_for(kind)
	if stream == null:
		return
	_ensure_voices()
	if _voices.is_empty():
		return
	var voice := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	voice.stream = stream
	voice.volume_db = _volume_db + float(TIER_GAIN_DB.get(kind, -8.0))
	voice.play()


func set_muted(on: bool) -> void:
	_muted = on
	_save_prefs()


func is_muted() -> bool:
	return _muted


func set_volume_db(db: float) -> void:
	_volume_db = clampf(db, -40.0, 6.0)
	_save_prefs()


func get_volume_db() -> float:
	return _volume_db


func _stream_for(kind: String) -> AudioStreamWAV:
	if _streams.has(kind):
		return _streams[kind]
	var s: AudioStreamWAV = build_stream(kind)
	_streams[kind] = s
	return s


func _ensure_voices() -> void:
	if not _voices.is_empty():
		return
	var bus := _ensure_ui_bus()
	for i in VOICE_COUNT:
		var p := AudioStreamPlayer.new()
		p.name = "UiVoice%d" % i
		p.bus = bus
		add_child(p)
		_voices.append(p)


## Route through a dedicated UI bus when we can create one, so a future audio
## manager (UX_IMPROVEMENT_PLAN Phase 7) has a single fader to grab. Falls back
## to Master when the audio server is unavailable.
func _ensure_ui_bus() -> String:
	if AudioServer.get_bus_index(BUS_NAME) >= 0:
		return BUS_NAME
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS_NAME)
	AudioServer.set_bus_send(idx, "Master")
	return BUS_NAME if AudioServer.get_bus_index(BUS_NAME) >= 0 else "Master"


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return
	_muted = bool(cfg.get_value("audio", "ui_muted", false))
	_volume_db = clampf(float(cfg.get_value("audio", "ui_volume_db", 0.0)), -40.0, 6.0)


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)  # keep any other sections
	cfg.set_value("audio", "ui_muted", _muted)
	cfg.set_value("audio", "ui_volume_db", _volume_db)
	cfg.save(PREFS_PATH)


# ---------------------------------------------------------------------------
# Synthesis (pure static — safe to call with no SceneTree / audio server)
# ---------------------------------------------------------------------------

static func build_stream(kind: String) -> AudioStreamWAV:
	match kind:
		SUCCESS:
			return build_success_stream()
		CONNECT:
			return build_connect_stream()
		WARN:
			return build_warn_stream()
		DANGER:
			return build_danger_stream()
		FANFARE:
			return build_fanfare_stream()
	return null


## Bell-ish partial stack. Real struck bars/bells carry odd partials that decay
## faster than the fundamental, which is what stops a pure sine reading as a
## test tone.
static func _bell(phase: float, bright: float) -> float:
	return sin(phase) + 0.30 * bright * sin(phase * 2.0) + 0.12 * bright * sin(phase * 3.0)


## Brass-ish stack (sawtooth-leaning) for the womp-womp — a sine slide reads as
## a theremin, the harmonics are what make it read as a trombone.
static func _brass(phase: float) -> float:
	return (sin(phase) + 0.50 * sin(phase * 2.0) + 0.33 * sin(phase * 3.0)
			+ 0.22 * sin(phase * 4.0)) * 0.55


static func _pack(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


## Two rising notes a fifth apart (E5 → B5). Short, bright, unmistakably "yes".
static func build_success_stream(seconds: float = 0.30) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * seconds)
	var out := PackedFloat32Array()
	out.resize(n)
	var notes := [{"f": 659.25, "at": 0.0}, {"f": 987.77, "at": 0.10}]
	for i in n:
		var t := float(i) / float(SAMPLE_RATE)
		var s := 0.0
		for note_v in notes:
			var note: Dictionary = note_v
			var lt: float = t - float(note["at"])
			if lt < 0.0:
				continue
			var env: float = clampf(lt / 0.003, 0.0, 1.0) * exp(-11.0 * lt)
			s += _bell(TAU * float(note["f"]) * lt, 1.0) * env * 0.5
		out[i] = clampf(s, -1.0, 1.0)
	return _pack(out)


## A short tick for "the wire landed". Deliberately tiny: it fires on every
## connection, so it has to sit under the conversation, not in it.
static func build_connect_stream(seconds: float = 0.07) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * seconds)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / float(SAMPLE_RATE)
		var env := clampf(t / 0.001, 0.0, 1.0) * exp(-42.0 * t)
		out[i] = clampf(sin(TAU * 2100.0 * t) * env * 0.75, -1.0, 1.0)
	return _pack(out)


## The "womp-womp": two descending pitch-bent brass notes with vibrato. Each
## note slides DOWN and the second starts below the first, which is the whole
## reason the gesture reads as deflation rather than alarm.
static func build_warn_stream(seconds: float = 0.62) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * seconds)
	var out := PackedFloat32Array()
	out.resize(n)
	# {start_hz, end_hz, at, dur}
	var notes := [
		{"f0": 233.08, "f1": 207.65, "at": 0.00, "dur": 0.26},
		{"f0": 196.00, "f1": 155.56, "at": 0.30, "dur": 0.32},
	]
	var phases := [0.0, 0.0]
	for i in n:
		var t := float(i) / float(SAMPLE_RATE)
		var s := 0.0
		for k in notes.size():
			var note: Dictionary = notes[k]
			var lt: float = t - float(note["at"])
			var dur: float = float(note["dur"])
			if lt < 0.0 or lt > dur:
				continue
			var u: float = lt / dur
			var vib: float = 1.0 + 0.02 * sin(TAU * 5.5 * lt)
			var f: float = lerpf(float(note["f0"]), float(note["f1"]), u * u) * vib
			phases[k] = float(phases[k]) + TAU * f / float(SAMPLE_RATE)
			var env: float = clampf(lt / 0.015, 0.0, 1.0) * clampf((dur - lt) / 0.06, 0.0, 1.0) \
					* exp(-1.9 * lt)
			s += _brass(float(phases[k])) * env * 0.7
		out[i] = clampf(s, -1.0, 1.0)
	return _pack(out)


## Explosion: body pitch-sweeping 90→40 Hz as the shock expands, plus a
## broadband crack with a very fast attack. Moved here from GraphCanvas so the
## destroy FX and the DANGER tier are literally the same sound; GraphCanvas
## still exposes build_boom_stream() as a thin delegate.
static func build_danger_stream(sample_rate: int = SAMPLE_RATE,
		seconds: float = 1.2) -> AudioStreamWAV:
	var n := int(sample_rate * seconds)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260729
	var phase := 0.0
	for i in n:
		var t := float(i) / float(sample_rate)
		var u := t / seconds
		phase += TAU * lerpf(90.0, 40.0, sqrt(u)) / float(sample_rate)
		var body := sin(phase) * exp(-3.0 * u)
		var crack := rng.randf_range(-1.0, 1.0) * exp(-18.0 * u)
		var attack := clampf(t / 0.004, 0.0, 1.0)
		var sample := clampf((body * 0.8 + crack * 0.5) * attack, -1.0, 1.0)
		data.encode_s16(i * 2, int(sample * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


## Rising major arpeggio (C5-E5-G5-C6), notes left ringing over each other, with
## a shimmer on the octave. Reserved for "you earned something".
static func build_fanfare_stream(seconds: float = 1.10) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * seconds)
	var out := PackedFloat32Array()
	out.resize(n)
	var notes := [
		{"f": 523.25, "at": 0.00},
		{"f": 659.25, "at": 0.11},
		{"f": 783.99, "at": 0.22},
		{"f": 1046.50, "at": 0.34},
	]
	for i in n:
		var t := float(i) / float(SAMPLE_RATE)
		var s := 0.0
		for note_v in notes:
			var note: Dictionary = note_v
			var lt: float = t - float(note["at"])
			if lt < 0.0:
				continue
			var env: float = clampf(lt / 0.004, 0.0, 1.0) * exp(-3.4 * lt)
			s += _bell(TAU * float(note["f"]) * lt, 0.8) * env * 0.34
		# Shimmer rides in with the octave and tremolos as it fades.
		var slt := t - 0.34
		if slt > 0.0:
			var trem: float = 0.5 + 0.5 * sin(TAU * 7.0 * slt)
			s += sin(TAU * 2093.0 * slt) * exp(-3.0 * slt) * trem * 0.10
		out[i] = clampf(s, -1.0, 1.0)
	return _pack(out)

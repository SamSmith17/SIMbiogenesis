class_name AmbientSynth
extends RefCounted

## Procedural ambience for the first-person bed when the player has put no
## file of their own in user://ambient/ (the repo ships NO audio — see
## ASSETS.md). Pure, deterministic (a seeded LCG, never randf), cheap: each
## loop is a few seconds of filtered noise made ONCE at load and looped by
## the player; the gusts, the bubbling and the chirp timing are done live on
## the players' volume and pitch, not in the samples.
##
## Every loop is made SEAMLESS: the tail is cross-faded into the head
## (overlap-add over XFADE_S) and the join is pinned by the selftest — a hard
## seam in a noise loop is a click twice a second, exactly the thing a player
## would hear.

const RATE := 22050
const LOOP_S := 3.0
const XFADE_S := 0.25
const PEAK := 0.85

static var _lcg := 0


static func _seed(s: int) -> void:
	_lcg = (s * 2654435761) & 0x7fffffff
	if _lcg == 0:
		_lcg = 1


## Uniform in [-1, 1).
static func _rand() -> float:
	_lcg = (_lcg * 1103515245 + 12345) & 0x7fffffff
	return float(_lcg) / 1073741824.0 - 1.0


## Cross-fade the last `fade` samples into the first `fade`, drop the tail:
## the loop point then has the same statistics as anywhere else.
static func make_seamless(samples: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := samples.size()
	fade = clampi(fade, 1, n / 2)
	var out := PackedFloat32Array()
	out.resize(n - fade)
	for i in n - fade:
		if i < fade:
			var t := float(i + 1) / float(fade + 1)
			out[i] = samples[i] * t + samples[n - fade + i] * (1.0 - t)
		else:
			out[i] = samples[i]
	return out


static func normalise(samples: PackedFloat32Array, peak: float = PEAK) -> PackedFloat32Array:
	var m := 0.0
	for s in samples:
		m = maxf(m, absf(s))
	if m <= 1e-6:
		return samples
	var out := PackedFloat32Array()
	out.resize(samples.size())
	var k := peak / m
	for i in samples.size():
		out[i] = samples[i] * k
	return out


## White noise through one-pole filters: `lp_hz` (0 = none) then `hp_hz`
## (0 = none). The building block of every bed.
static func filtered_noise(seconds: float, lp_hz: float, hp_hz: float, seed: int, rate: int = RATE) -> PackedFloat32Array:
	_seed(seed)
	var n := int(seconds * rate)
	var out := PackedFloat32Array()
	out.resize(n)
	var a_lp := 1.0 - exp(-2.0 * PI * lp_hz / float(rate)) if lp_hz > 0.0 else 1.0
	var a_hp := exp(-2.0 * PI * hp_hz / float(rate)) if hp_hz > 0.0 else 0.0
	var lp := 0.0
	var hp_prev_in := 0.0
	var hp := 0.0
	for i in n:
		var x := _rand()
		lp += a_lp * (x - lp)
		var y := lp
		if hp_hz > 0.0:
			hp = a_hp * (hp + y - hp_prev_in)
			hp_prev_in = y
			y = hp
		out[i] = y
	return out


## Wind: deep rushing noise (low-passed ~350 Hz). Gusts are live.
static func wind_loop(seed: int = 11, seconds: float = LOOP_S, rate: int = RATE) -> PackedFloat32Array:
	var raw := filtered_noise(seconds, 350.0, 20.0, seed, rate)
	return normalise(make_seamless(raw, int(XFADE_S * rate)))


## Rain: bright hiss (high-passed ~900 Hz) with sparse drops on top.
static func rain_loop(seed: int = 23, seconds: float = LOOP_S, rate: int = RATE) -> PackedFloat32Array:
	var raw := filtered_noise(seconds, 6000.0, 900.0, seed, rate)
	_seed(seed + 7)
	var n := raw.size()
	var drops := int(seconds * 90.0)
	for _d in drops:
		var at := int((_rand() * 0.5 + 0.5) * float(n - 64))
		var amp := 0.6 + 0.4 * (_rand() * 0.5 + 0.5)
		for k in 48:
			var env := amp * exp(-float(k) / 9.0)
			raw[at + k] += env * (1.0 if (k % 4) < 2 else -1.0) * 0.5
	return normalise(make_seamless(raw, int(XFADE_S * rate)))


## A stream: mid-band wash (150–1500 Hz) with a slow two-tone bubbling.
static func stream_loop(seed: int = 37, seconds: float = LOOP_S, rate: int = RATE) -> PackedFloat32Array:
	var raw := filtered_noise(seconds, 1500.0, 150.0, seed, rate)
	var n := raw.size()
	for i in n:
		var t := float(i) / float(rate)
		var am := 1.0 + 0.15 * sin(TAU * 3.1 * t) + 0.12 * sin(TAU * 7.3 * t + 1.0)
		raw[i] *= am
	return normalise(make_seamless(raw, int(XFADE_S * rate)))


## One bird call: 2–4 short sine sweeps with attack / decay, gaps between.
## Pitch and timing vary live (pitch_scale, the scheduler); `seed` picks the
## shape.
static func chirp(seed: int, rate: int = RATE) -> PackedFloat32Array:
	_seed(seed)
	var notes := 2 + int((_rand() * 0.5 + 0.5) * 2.99)
	var out := PackedFloat32Array()
	for _k in notes:
		var f0 := 2500.0 + (_rand() * 0.5 + 0.5) * 2000.0
		var sweep := (_rand()) * 0.35                     # -35 % .. +35 % over the note
		var len_s := 0.06 + (_rand() * 0.5 + 0.5) * 0.07
		var gap_s := 0.03 + (_rand() * 0.5 + 0.5) * 0.06
		var n := int(len_s * rate)
		var phase := 0.0
		for i in n:
			var u := float(i) / float(n)
			var f := f0 * (1.0 + sweep * u)
			phase += TAU * f / float(rate)
			var env := minf(u / 0.15, 1.0) * (1.0 - u) * (1.0 - u)
			out.append(sin(phase) * env * 0.8)
		var g := int(gap_s * rate)
		for _i in g:
			out.append(0.0)
	return out


## 16-bit mono AudioStreamWAV, looped or one-shot.
static func to_wav(samples: PackedFloat32Array, looped: bool, rate: int = RATE) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	wav.data = data
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	else:
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav


# --- what the selftest measures --------------------------------------------------

static func rms(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0
	var acc := 0.0
	for s in samples:
		acc += s * s
	return sqrt(acc / float(samples.size()))


static func peak_abs(samples: PackedFloat32Array) -> float:
	var m := 0.0
	for s in samples:
		m = maxf(m, absf(s))
	return m


## How much the loop point sticks out: the largest sample-to-sample step
## across the join against the largest step inside the loop. ≤ 1 = seamless.
static func seam_ratio(samples: PackedFloat32Array) -> float:
	var n := samples.size()
	if n < 3:
		return 0.0
	var inner := 0.0
	for i in range(1, n):
		inner = maxf(inner, absf(samples[i] - samples[i - 1]))
	var join := absf(samples[0] - samples[n - 1])
	return join / maxf(inner, 1e-9)


## Mean |x| of the first-difference signal over the signal's own: a rough
## brightness (0 = DC, 2 = alternating). How the three beds are told apart.
static func brightness(samples: PackedFloat32Array) -> float:
	if samples.size() < 2:
		return 0.0
	var d := 0.0
	var m := 0.0
	for i in range(1, samples.size()):
		d += absf(samples[i] - samples[i - 1])
		m += absf(samples[i])
	return d / maxf(m, 1e-9)

class_name LedEffects
extends RefCounted

## Addressable-LED effects for placed string lights — the CPU half.
##
## `color_at` is the ONE definition of every effect. gameplay/led_bulb.gdshader
## carries a line-for-line MIRROR of it (it draws the bulbs on the GPU from the
## same parameters, with the bulb index in INSTANCE_CUSTOM.r), and a string's
## real OmniLights call this directly at their own bulb indices so the light on
## the ground chases along with the bulbs. Edit both or the cast light and the
## bulbs disagree; placed_lights_selftest pins the shared constants.
##
## Time is supplied by the caller (PlacedStringLight pushes the same `t` to the
## shader as a uniform), so the two halves never sample different clocks.
##
## Parameters (all flat keys on the resolved light record):
##   effect          id from EFFECTS
##   fx_speed        bulbs per second for chases / wipes; cycles per ~4 s otherwise
##   fx_span         bulbs per full rainbow (rainbow_chase)
##   fx_gap          theatre-chase period in bulbs (every Nth bulb lit)
##   fx_saturation   0..1, rainbow / wipe saturation
##   fx_direction    +1 forward, -1 reverse

const EFFECTS: Array[String] = ["solid", "rainbow_chase", "chase", "twinkle", "breathe",
	"color_wipe", "flicker", "strobe"]
const EFFECT_LABELS: Array[String] = ["Solid", "Rainbow chase", "Theatre chase", "Twinkle",
	"Breathe", "Colour wipe", "Flicker (flame / lantern)", "Strobe"]

## Shared with gameplay/led_effects.gdshaderinc (the selftest parses them out).
const TWINKLE_FLOOR := 0.18
const BREATHE_FLOOR := 0.12
const CHASE_DIM := 0.06
const WIPE_HUE_STEP := 0.17
const BREATHE_BULBS := 16.0
const FLICKER_FLOOR := 0.35
## Strobe: share of each flash period the lamp is lit (fx_speed = flashes/s).
const STROBE_DUTY := 0.12


static func effect_index(id: String) -> int:
	return maxi(EFFECTS.find(id), 0)


## Colour of bulb `i` of `n` at time `t` (s). `base` is the light's own colour.
## The returned colour is linear-ish display RGB in 0..1 (the caller applies
## energy); alpha is unused.
static func color_at(fx: Dictionary, i: int, n: int, t: float, base: Color) -> Color:
	var mode := effect_index(str(fx.get("effect", "solid")))
	var speed := float(fx.get("fx_speed", 6.0))
	var span := maxf(float(fx.get("fx_span", 24.0)), 1.0)
	var gap := maxf(roundf(float(fx.get("fx_gap", 3.0))), 2.0)
	var sat := clampf(float(fx.get("fx_saturation", 1.0)), 0.0, 1.0)
	var dir := -1.0 if float(fx.get("fx_direction", 1.0)) < 0.0 else 1.0
	var x := float(i) * dir
	match mode:
		1:  # rainbow chase — hue walks along the string at `speed` bulbs/s
			var h := fposmod((x - speed * t) / span, 1.0)
			return Color.from_hsv(h, sat, 1.0)
		2:  # theatre chase — every gap-th bulb lit, stepping at `speed` bulbs/s
			var k := fposmod(x - floorf(speed * t), gap)
			return base if k < 1.0 else base * CHASE_DIM
		3:  # twinkle — each bulb on its own seeded phase and rate
			var r1 := hash11(float(i) + 0.5)
			var r2 := hash11(float(i) * 1.7 + 11.3)
			var w := 0.5 + 0.5 * sin(t * speed * (0.35 + r2) + r1 * TAU)
			return base * (TWINKLE_FLOOR + (1.0 - TWINKLE_FLOOR) * w * w * w)
		4:  # breathe — the whole string swells together
			# One breath every BREATHE_BULBS / speed seconds (2.7 s at speed 6).
			var b := 0.5 - 0.5 * cos(TAU * t * speed / BREATHE_BULBS)
			return base * (BREATHE_FLOOR + (1.0 - BREATHE_FLOOR) * b)
		5:  # colour wipe — a new colour fills the string one bulb at a time
			var nn := float(maxi(n, 1))
			var head := speed * t
			var cycle := floorf(head / nn)
			var pos := head - cycle * nn
			var idx := x if dir > 0.0 else nn - 1.0 + x
			var c := cycle if idx < pos else cycle - 1.0
			return Color.from_hsv(fposmod(c * WIPE_HUE_STEP, 1.0), sat, 1.0)
		6:  # flicker — flame, candle, lantern: three incommensurate wobbles
			var f1 := hash11(float(i) + 0.5)
			var f2 := hash11(float(i) * 1.7 + 11.3)
			var fw := 0.55 + 0.22 * sin(t * speed * 1.3 + f1 * TAU)
			fw += 0.15 * sin(t * speed * 3.1 + f2 * TAU)
			fw += 0.08 * sin(t * speed * 7.7 + f1 * 17.0)
			return base * (FLICKER_FLOOR + (1.0 - FLICKER_FLOOR) * clampf(fw, 0.0, 1.0))
		7:  # strobe — fx_speed flashes per second
			return base if fposmod(t * speed, 1.0) < STROBE_DUTY else Color(0, 0, 0)
		_:
			return base


## Dave Hoskins' hash11 (fract-based, no trig) — identical maths in the shader.
static func hash11(p: float) -> float:
	p = fposmod(p * 0.1031, 1.0)
	p *= p + 33.33
	p *= p + p
	return fposmod(p, 1.0)

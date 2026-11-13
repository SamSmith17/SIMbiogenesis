class_name GraphFlowStyle
extends RefCounted

## THE flow style of the graph's wires (plans: now-i-want-to-linked-garden).
## One graph-wide setting decides how flow shows on every wire: how wide a
## wire is for the amount it carries, how it animates, how much it glows.
## Pure: the canvas, the Flows lens, the 3D view connectors and the selftest
## all ask the same functions.
##
## A Sankey rule: inside ONE resource, a wire's width is proportional to what
## it carries (linear mode), measured against the biggest flow of that
## resource on screen (`ref`, eased by the caller). Different resources are
## never compared — each keeps its own scale bar (the user's decision).

const PRESET_CLASSIC := "classic"   # the old per-kind look, old renderer
const PRESET_SUBTLE := "subtle"
const PRESET_SANKEY := "sankey"
const PRESET_BOLD := "bold"
const PRESET_CUSTOM := "custom"
## Looks: the same width rule, dressed differently.
const PRESET_NEON := "neon"
const PRESET_AURORA := "aurora"
const PRESET_INK := "ink"
const PRESET_EMBER := "ember"
const PRESETS := [PRESET_CLASSIC, PRESET_SUBTLE, PRESET_SANKEY, PRESET_BOLD,
	PRESET_NEON, PRESET_AURORA, PRESET_INK, PRESET_EMBER]
## The width presets and the look presets, for two rows of buttons.
const WIDTH_PRESETS := [PRESET_CLASSIC, PRESET_SUBTLE, PRESET_SANKEY, PRESET_BOLD]
const LOOK_PRESETS := [PRESET_NEON, PRESET_AURORA, PRESET_INK, PRESET_EMBER]
const PRESET_LABELS := {
	PRESET_CLASSIC: "Classic",
	PRESET_SUBTLE: "Subtle",
	PRESET_SANKEY: "Sankey",
	PRESET_BOLD: "Bold",
	PRESET_NEON: "Neon",
	PRESET_AURORA: "Aurora",
	PRESET_INK: "Ink",
	PRESET_EMBER: "Ember",
	PRESET_CUSTOM: "Custom",
}
const PRESET_TIPS := {
	PRESET_CLASSIC: "The old wires: thin, a little wider when busy, arrows and dots",
	PRESET_SUBTLE: "Width follows flow gently (square root), slow beads",
	PRESET_SANKEY: "Width proportional to flow in each resource, moving streaks",
	PRESET_BOLD: "Thick ribbons that stay bold when zoomed out, bright comets",
	PRESET_NEON: "Glowing tubes with a white-hot core and fast comets",
	PRESET_AURORA: "Soft, wide light that shimmers along the wires, tapered ends",
	PRESET_INK: "Flat, printed ribbons with dark edges, no glow",
	PRESET_EMBER: "Coloured by how much flows: deep red trickles to white-hot rivers",
}

## Colour modes: the resource's colour, the same lightening toward the
## destination, a heat ramp by how much flows, an aurora shimmer, one accent.
const COLOUR_KIND := "kind"
const COLOUR_GRADIENT := "gradient"
const COLOUR_HEAT := "heat"
const COLOUR_AURORA := "aurora"
const COLOUR_MONO := "mono"
const COLOURS := [COLOUR_GRADIENT, COLOUR_KIND, COLOUR_HEAT, COLOUR_AURORA, COLOUR_MONO]
const COLOUR_LABELS := {
	COLOUR_GRADIENT: "Resource, toward the end",
	COLOUR_KIND: "Resource colour",
	COLOUR_HEAT: "Heat (by how much)",
	COLOUR_AURORA: "Aurora shimmer",
	COLOUR_MONO: "One accent colour",
}

const SCALE_LINEAR := "linear"
const SCALE_SQRT := "sqrt"
const SCALE_LOG := "log"
const SCALES := [SCALE_LINEAR, SCALE_SQRT, SCALE_LOG]
const SCALE_LABELS := {
	SCALE_LINEAR: "Proportional",
	SCALE_SQRT: "Square root",
	SCALE_LOG: "Logarithmic",
}

const ANIM_NONE := "none"
const ANIM_BEADS := "beads"
const ANIM_STREAKS := "streaks"
const ANIM_COMETS := "comets"
const ANIM_PULSE := "pulse"
const ANIMS := [ANIM_STREAKS, ANIM_COMETS, ANIM_BEADS, ANIM_PULSE, ANIM_NONE]
const ANIM_LABELS := {
	ANIM_NONE: "Still",
	ANIM_BEADS: "Beads",
	ANIM_STREAKS: "Streaks",
	ANIM_COMETS: "Comets",
	ANIM_PULSE: "Pulse",
}

const REF_SCREEN := "screen"      # biggest flow of each resource in this scope
const REF_KIND := "kind"          # each resource's fixed reference rate
const REFS := [REF_SCREEN, REF_KIND]
const REF_LABELS := {
	REF_SCREEN: "Biggest flow here",
	REF_KIND: "Fixed per resource",
}

## Display averaging in SIM hours (0 = instantaneous).
const SMOOTHING_CHOICES := [0.0, 0.25, 1.0, 24.0]

## Keys a style dict carries. `thickness` = width in px of the reference
## (biggest) flow at 100 % zoom; `min_px` the width of a live trickle;
## `idle_px` a wire carrying nothing; `screen_space` keeps widths in screen
## pixels whatever the zoom (zoomed out the ribbons stay bold);
## `speed` scales the animation; `glow` 0..1.
const DEFAULTS := {
	"preset": PRESET_SANKEY,
	"scale": SCALE_LINEAR,
	"thickness": 22.0,
	"min_px": 2.5,
	"idle_px": 1.6,
	"screen_space": false,
	"zoom_floor": 0.55,
	"ref": REF_SCREEN,
	"smoothing_h": 0.0,
	"anim": ANIM_STREAKS,
	"speed": 1.0,
	"glow": 0.6,
	"legend": true,
	# The look (GraphFlowRibbons): glow width (× the ribbon's half width), the
	# white-hot core (strength, share of the width), the darkened rim, how
	# much a streak swells the ribbon, how much the ends taper, saturation,
	# brightness, the colour mode and its accent, how faint an idle wire is,
	# the pattern's spacing (× its natural period) and length (0..1).
	"glow_w": 1.6,
	"core": 0.35,
	"core_w": 0.3,
	"rim": 0.45,
	"swell": 0.15,
	"taper": 0.0,
	"sat": 1.0,
	"bright": 1.0,
	"colour": COLOUR_GRADIENT,
	"accent": "8cd9ff",
	"idle_alpha": 0.65,
	"period": 1.0,
	"duty": 0.5,
	# The Flows lens: space between layers, node width, how far the returns
	# stand off the column, their opacity, the label size.
	"lens_gap": 74.0,
	"lens_node_w": 170.0,
	"lens_return_gap": 46.0,
	"lens_return_alpha": 0.86,
	"lens_label": 1.0,
}

## Ranges of the look keys (UI sliders and clamping).
const LOOK_RANGES := {
	"glow_w": [0.3, 5.0], "core": [0.0, 1.0], "core_w": [0.05, 0.9], "rim": [0.0, 1.0],
	"swell": [0.0, 1.0], "taper": [0.0, 1.0], "sat": [0.0, 2.0], "bright": [0.4, 2.0],
	"idle_alpha": [0.0, 1.0], "period": [0.3, 4.0], "duty": [0.05, 1.0],
	"lens_gap": [36.0, 220.0], "lens_node_w": [80.0, 320.0], "lens_return_gap": [16.0, 140.0],
	"lens_return_alpha": [0.1, 1.0], "lens_label": [0.6, 1.8],
}

const PRESET_VALUES := {
	PRESET_CLASSIC: {},
	PRESET_SUBTLE: {"scale": SCALE_SQRT, "thickness": 12.0, "min_px": 2.0,
		"anim": ANIM_BEADS, "speed": 0.7, "glow": 0.3, "screen_space": false, "zoom_floor": 0.4},
	PRESET_SANKEY: {"scale": SCALE_LINEAR, "thickness": 22.0, "min_px": 2.5,
		"anim": ANIM_STREAKS, "speed": 1.0, "glow": 0.6, "screen_space": false, "zoom_floor": 0.55},
	PRESET_BOLD: {"scale": SCALE_LINEAR, "thickness": 34.0, "min_px": 3.5,
		"anim": ANIM_COMETS, "speed": 1.15, "glow": 0.9, "screen_space": true,
		"core": 0.5, "swell": 0.25},
	PRESET_NEON: {"scale": SCALE_LINEAR, "thickness": 24.0, "min_px": 2.5,
		"anim": ANIM_COMETS, "speed": 1.25, "glow": 1.0, "glow_w": 2.9, "core": 0.9,
		"core_w": 0.2, "rim": 0.15, "swell": 0.3, "sat": 1.4, "bright": 1.15,
		"colour": COLOUR_GRADIENT, "period": 1.25, "duty": 0.35, "idle_alpha": 0.45,
		"zoom_floor": 0.6},
	PRESET_AURORA: {"scale": SCALE_SQRT, "thickness": 30.0, "min_px": 3.0,
		"anim": ANIM_STREAKS, "speed": 0.7, "glow": 0.9, "glow_w": 3.4, "core": 0.25,
		"core_w": 0.45, "rim": 0.05, "swell": 0.12, "taper": 0.55, "sat": 1.2,
		"bright": 1.05, "colour": COLOUR_AURORA, "period": 2.2, "duty": 0.85,
		"idle_alpha": 0.5, "zoom_floor": 0.6},
	PRESET_INK: {"scale": SCALE_LINEAR, "thickness": 20.0, "min_px": 2.0,
		"anim": ANIM_BEADS, "speed": 0.8, "glow": 0.0, "core": 0.0, "rim": 0.9,
		"swell": 0.0, "sat": 0.7, "bright": 0.95, "colour": COLOUR_KIND, "period": 0.9,
		"duty": 0.3, "idle_alpha": 0.4},
	PRESET_EMBER: {"scale": SCALE_LINEAR, "thickness": 26.0, "min_px": 2.5,
		"anim": ANIM_COMETS, "speed": 1.05, "glow": 0.8, "glow_w": 2.2, "core": 0.6,
		"core_w": 0.28, "rim": 0.35, "swell": 0.25, "taper": 0.3, "colour": COLOUR_HEAT,
		"period": 1.0, "duty": 0.45},
}

## Ranges for the UI and for clamping saved values.
const THICKNESS_MIN := 4.0
const THICKNESS_MAX := 80.0
const MIN_PX_MAX := 12.0
const SPEED_MAX := 3.0

## Per-wire overrides (`conn.flow_width`): "" = the graph's style.
const WIRE_INHERIT := ""
const WIRE_PLAIN := "plain"       # never scales with flow
const WIRE_EMPHASIS := "x2"       # twice the graph's width
const WIRE_CHOICES := [WIRE_INHERIT, WIRE_PLAIN, WIRE_EMPHASIS]
const WIRE_LABELS := {
	WIRE_INHERIT: "Graph's flow style",
	WIRE_PLAIN: "Plain (no flow width)",
	WIRE_EMPHASIS: "Emphasise (2× wide)",
}

## Pixels per second the animation never exceeds: past this a stripe pattern
## strobes instead of moving, which is what made wires unreadable at speed.
const MAX_ANIM_PX_S := 140.0
const MIN_ANIM_PX_S := 14.0


## A complete, clamped style from a sparse dict (a save, the prefs, a panel).
## A known preset fills its values first; any key the dict sets itself wins
## (that is what makes it "custom").
static func resolve(d: Variant) -> Dictionary:
	var out := DEFAULTS.duplicate()
	var src: Dictionary = d if d is Dictionary else {}
	var preset := str(src.get("preset", out["preset"]))
	if not PRESET_LABELS.has(preset):
		preset = PRESET_SANKEY
	out["preset"] = preset
	var pv: Dictionary = PRESET_VALUES.get(preset, {}) as Dictionary
	for k in pv:
		out[k] = pv[k]
	for k in src:
		if k == "preset" or not DEFAULTS.has(k):
			continue
		out[k] = src[k]
	# The old bool: "brighter toward the destination" off = one flat colour.
	if src.has("gradient") and not src.has("colour") and not bool(src["gradient"]):
		out["colour"] = COLOUR_KIND
	out["scale"] = str(out["scale"]) if SCALES.has(str(out["scale"])) else SCALE_LINEAR
	out["anim"] = str(out["anim"]) if ANIMS.has(str(out["anim"])) else ANIM_STREAKS
	out["ref"] = str(out["ref"]) if REFS.has(str(out["ref"])) else REF_SCREEN
	out["thickness"] = clampf(float(out["thickness"]), THICKNESS_MIN, THICKNESS_MAX)
	out["min_px"] = clampf(float(out["min_px"]), 0.5, MIN_PX_MAX)
	out["idle_px"] = clampf(float(out["idle_px"]), 0.5, MIN_PX_MAX)
	out["speed"] = clampf(float(out["speed"]), 0.0, SPEED_MAX)
	out["glow"] = clampf(float(out["glow"]), 0.0, 1.0)
	out["smoothing_h"] = maxf(0.0, float(out["smoothing_h"]))
	out["screen_space"] = bool(out["screen_space"])
	out["zoom_floor"] = clampf(float(out["zoom_floor"]), 0.0, 1.0)
	out["legend"] = bool(out["legend"])
	out["colour"] = str(out["colour"]) if COLOURS.has(str(out["colour"])) else COLOUR_GRADIENT
	out["accent"] = str(out["accent"]).trim_prefix("#")
	if not Color.html_is_valid(str(out["accent"])):
		out["accent"] = "8cd9ff"
	for k in LOOK_RANGES:
		var rg: Array = LOOK_RANGES[k]
		out[k] = clampf(float(out[k]), float(rg[0]), float(rg[1]))
	return out


## The keys GraphFlowRibbons draws with, from a style.
static func look(style: Dictionary) -> Dictionary:
	return {"glow": float(style.get("glow", 0.6)), "glow_w": float(style.get("glow_w", 1.6)),
		"core": float(style.get("core", 0.35)), "core_w": float(style.get("core_w", 0.3)),
		"rim": float(style.get("rim", 0.45)), "swell": float(style.get("swell", 0.15)),
		"taper": float(style.get("taper", 0.0)), "sat": float(style.get("sat", 1.0)),
		"bright": float(style.get("bright", 1.0)), "colour": str(style.get("colour", COLOUR_GRADIENT)),
		"accent": Color.html(str(style.get("accent", "8cd9ff"))),
		"idle_alpha": float(style.get("idle_alpha", 0.65)), "period": float(style.get("period", 1.0)),
		"duty": float(style.get("duty", 0.5))}


## The sparse form saved with the graph: only what differs from the preset
## (so a later change to a preset reaches graphs that use it).
static func to_sparse(style: Dictionary) -> Dictionary:
	var full := resolve(style)
	var preset := str(full["preset"])
	var base := resolve({"preset": preset})
	var out := {"preset": preset}
	for k in DEFAULTS:
		if k == "preset":
			continue
		if not _same(full[k], base[k]):
			out[k] = full[k]
	return out


## Is this the old renderer? (The classic preset with nothing changed.)
static func is_classic(style: Dictionary) -> bool:
	return str(style.get("preset", "")) == PRESET_CLASSIC


## The preset name a style reads as: its own, or "custom" once it differs.
static func label_of(style: Dictionary) -> String:
	var sp := to_sparse(style)
	if sp.size() > 1:
		return PRESET_LABELS[PRESET_CUSTOM]
	return str(PRESET_LABELS.get(str(sp["preset"]), "Sankey"))


## 0..1 position of `value` against `ref` on the style's scale.
static func norm(value: float, ref: float, scale: String) -> float:
	if value <= 0.0 or ref <= 0.0:
		return 0.0
	var x := value / ref
	match scale:
		SCALE_SQRT:
			return clampf(sqrt(x), 0.0, 1.5)
		SCALE_LOG:
			# log10(1 + 9x): 0 → 0, ref → 1, ten times the ref → ~1.95.
			return clampf(log(1.0 + 9.0 * x) / log(10.0), 0.0, 1.5)
	return clampf(x, 0.0, 1.5)


## The wire's width in SCREEN pixels. `active` = something moves on it;
## `zoom` the canvas zoom; `wire` the per-wire override.
static func width_px(style: Dictionary, value: float, ref: float, active: bool,
		zoom: float, wire: String = WIRE_INHERIT) -> float:
	# Widths follow the zoom, but never shrink below `zoom_floor` of their
	# 100 % size: zoomed out a Sankey must still read as one.
	var z := 1.0 if bool(style.get("screen_space", false)) else maxf(maxf(zoom, 0.01), float(style.get("zoom_floor", 0.0)))
	var idle := float(style.get("idle_px", 1.6))
	if not active or value <= 0.0:
		return maxf(1.0, idle * minf(z, 1.4))
	if wire == WIRE_PLAIN:
		return maxf(1.0, float(style.get("min_px", 2.5)) * 1.3 * minf(z, 1.6))
	var n := norm(value, ref, str(style.get("scale", SCALE_LINEAR)))
	var w := float(style.get("thickness", 22.0)) * n
	if wire == WIRE_EMPHASIS:
		w *= 2.0
	# The trickle floor and the idle width are on-screen sizes: a live wire
	# must never shrink below a readable line however far out you zoom.
	var floor_px := float(style.get("min_px", 2.5))
	return maxf(floor_px, w * z)


## How fast the pattern moves along a wire, in screen px per real second.
## Encodes MAGNITUDE (more flow, faster), never the sim speed: the sim speed
## only decides whether anything moves. Logarithmic, capped below strobing.
static func anim_speed_px(style: Dictionary, value: float, ref: float) -> float:
	var k := float(style.get("speed", 1.0))
	if k <= 0.0 or value <= 0.0 or ref <= 0.0:
		return 0.0
	var x := clampf(value / ref, 0.0, 4.0)
	var s := MIN_ANIM_PX_S + (MAX_ANIM_PX_S - MIN_ANIM_PX_S) * 0.55 \
			* log(1.0 + 9.0 * x) / log(10.0)
	return clampf(s * k, 0.0, MAX_ANIM_PX_S * maxf(1.0, k))


## Brightness of the flow pattern at arc length `s_px` (0..1). `t` = the
## pattern clock in seconds, `speed` px/s from anim_speed_px, `blur` true at
## high sim speed (long soft streaks that cannot strobe). Pure, so the
## selftest checks it moves the right way.
static func pattern(anim: String, s_px: float, t: float, speed: float,
		reverse: bool, blur: bool = false) -> float:
	return pattern_ex(anim, s_px, t, speed, reverse, blur, 1.0, 0.5)


## The pattern with the style's spacing (`period` × the natural one) and
## length (`duty` 0..1: 0.5 is the natural shape, toward 1 the streaks and
## tails grow long and soft, toward 0 they shrink to sparks).
static func pattern_ex(anim: String, s_px: float, t: float, speed: float,
		reverse: bool, blur: bool, period: float, duty: float) -> float:
	if anim == ANIM_NONE:
		return 0.0
	var p := s_px - t * speed if not reverse else s_px + t * speed
	var pm := maxf(period, 0.05)
	var dk := pow(2.0, (0.5 - clampf(duty, 0.0, 1.0)) * 3.0)
	match anim:
		ANIM_PULSE:
			return 0.5 + 0.5 * sin(TAU * p / (160.0 * pm))
		ANIM_BEADS:
			var per_b := 26.0 * pm
			var xb := fposmod(p, per_b) / per_b
			var d := absf(xb - 0.5) * 2.0
			return clampf(1.0 - d * 1.6 * pow(2.0, (0.5 - duty) * 2.0), 0.0, 1.0)
		ANIM_COMETS:
			var per_c := (96.0 if not blur else 150.0) * pm
			var xc := fposmod(p, per_c) / per_c
			# Bright head at the front (x near 1 when moving forward), a long tail.
			var head := xc if not reverse else 1.0 - xc
			return pow(head, (5.0 if not blur else 2.4) * pow(dk, 0.85))
	# Streaks (default)
	var per := (44.0 if not blur else 110.0) * pm
	var x := fposmod(p, per) / per
	var h := x if not reverse else 1.0 - x
	if blur:
		return pow(h, 1.6) * 0.8
	return pow(h, 3.0 * dk)


## Display smoothing: ease `prev` toward `now` over `dt_h` sim hours with
## time constant `tau_h`. Exact for any step (1 − e^(−dt/τ)).
static func ease_rate(prev: float, now: float, dt_h: float, tau_h: float) -> float:
	if tau_h <= 0.0 or dt_h < 0.0:
		return now
	if is_nan(prev):
		return now
	var a := 1.0 - exp(-dt_h / tau_h)
	return prev + (now - prev) * a


## The reference the screen-relative scale measures against: eased toward
## this frame's biggest flow so the whole graph does not jump when one wire
## spikes. Rises fast, falls slowly (a peak-hold).
static func ease_ref(prev: float, frame_max: float, dt_s: float) -> float:
	if frame_max <= 0.0:
		return prev
	if prev <= 0.0 or is_nan(prev):
		return frame_max
	var rate := 6.0 if frame_max > prev else 0.6
	var a := 1.0 - exp(-maxf(dt_s, 0.0) * rate)
	return prev + (frame_max - prev) * a


## The key a wire's flow is scaled by: the resource kind for typed wires,
## "electricity" for power wires. (Each resource keeps its own scale.)
static func scale_key(is_resource: bool, kind: String) -> String:
	if not is_resource:
		return "electricity"
	return kind if kind != "" else "resource"


## A legend row's value: a round number near the reference so the scale bar
## reads "▬ 1 kW" rather than "▬ 943 W". Returns [value, frac of ref].
static func legend_tick(ref: float) -> Array:
	if ref <= 0.0:
		return [0.0, 0.0]
	var mag := pow(10.0, floor(log(ref) / log(10.0)))
	var best := mag
	for m in [1.0, 2.0, 5.0, 10.0]:
		if mag * m <= ref * 1.0001:
			best = mag * m
	return [best, best / ref]


## Migration of the old per-wire checkbox: `sankey_scale: false` meant "do
## not scale this wire" — that is now the plain override.
static func wire_override(conn: Dictionary) -> String:
	var ov := str(conn.get("flow_width", ""))
	if WIRE_CHOICES.has(ov):
		if ov != WIRE_INHERIT:
			return ov
	if conn.has("sankey_scale") and not bool(conn.get("sankey_scale", true)):
		return WIRE_PLAIN
	return WIRE_INHERIT


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) < 1e-6
	return a == b

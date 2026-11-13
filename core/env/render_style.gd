class_name RenderStyle
extends RefCounted
## Visual styles ("skins") for the whole world: Settings → Lighting → Visual style.
##
## Pure data. A style is two sets of numbers:
##   - ENV: multipliers on what Main computes for the environment each update
##     (ambient, haze, glow) plus the Environment's post-tonemap adjustment.
##     Applied by Main at the END of its environment update, so they multiply
##     freshly computed values and are idempotent (apply_env).
##   - POST: the RenderStyleEffect compute pass (painterly smoothing, cel light
##     bands, ink outlines, colour grade) — RenderStyleDriver hands these over.
##
## "realistic" is the identity: every number is the value that changes nothing,
## and the effect is switched off. resolve() blends any style toward it by
## strength, so strength 0 IS realistic (pinned in render_style_selftest).

const REALISTIC := "realistic"
const SOLARPUNK := "solarpunk"
const WATERCOLOR := "watercolor"
const INK := "ink"
const CINEMATIC := "cinematic"

## Shown in the Lighting page, in this order.
const ORDER := [REALISTIC, SOLARPUNK, WATERCOLOR, INK, CINEMATIC]

const LABELS := {
	REALISTIC: "Realistic",
	SOLARPUNK: "Solarpunk (painted)",
	WATERCOLOR: "Storybook watercolor",
	INK: "Ink & halftone (graphic novel)",
	CINEMATIC: "Cinematic (teal & orange)",
}

const BLURBS := {
	REALISTIC: "The world as the lighting model computes it.",
	SOLARPUNK: "Bright, saturated and hand-painted: soft cel-shaded light, ink outlines, painterly foliage, cool teal shadows and warm highlights, clear air and a deep blue sky.",
	WATERCOLOR: "A picture-book painting: soft washes of colour on warm textured paper, pale lifted shadows with a violet cast, loose sepia lines round near things, and a gentle haze.",
	INK: "A graphic novel: bold black ink lines, hard-edged light, shadows printed as a halftone dot screen, and an almost monochrome blue-and-cream palette on paper.",
	CINEMATIC: "A film grade: teal shadows and warm orange light, extra contrast, a soft bloom, a vignette and fine moving film grain. No lines or painting.",
}

## The values that change nothing. Every style lists every key.
const IDENTITY := {
	# --- environment (multipliers on Main's values, adjustment absolute) ---
	"ambient_mult": 1.0,
	"fog_mult": 1.0,
	"aerial_mult": 1.0,
	"glow_int_mult": 1.0,
	"glow_threshold_mult": 1.0,
	"glow_bloom": 0.0,
	"adj_saturation": 1.0,
	"adj_contrast": 1.0,
	"adj_brightness": 1.0,
	# --- post pass ---
	"kuwahara_px": 0.0,        # painterly radius, pixels at 1080 lines
	"band_mix": 0.0,           # 0 smooth light, 1 hard cel bands
	"band_stops": 1.0,         # light band width in exposure stops
	"band_soft": 0.25,         # softness of a band edge (0..0.5)
	"light_compress": 0.0,     # flatten the lighting range around mid grey
	"outline_mix": 0.0,
	"outline_px": 1.0,         # line half-reach, pixels at 1080 lines
	"outline_depth_t": 0.012,  # relative depth kink that starts a line
	"outline_normal_t": 0.35,  # 1 - cos(angle) that starts a crease line
	"outline_dark": 0.25,      # line colour = the pixel's own colour × this
	"outline_fade_start": 30.0,
	"outline_fade_end": 250.0,
	"outline_normals": 1.0,    # crease lines from normals (0 = silhouettes only)
	"saturation": 1.0,
	"vibrance": 0.0,
	"sky_saturation": 1.0,
	"sky_cyan": 0.0,           # push the daytime sky toward a clear cyan-blue
	"green_push": 0.0,         # turn olive / yellow-green foliage toward fresh green
	# --- finish (the effect's uniform buffer) ---
	"lift": 0.0,               # lifted blacks, in mid-grey units
	"grain": 0.0,              # paper texture / film grain strength
	"grain_film": 0.0,         # 0 still paper texture, 1 moving film grain
	"vignette": 0.0,
	"paper_tint": Color(1, 1, 1),
	"paper_mix": 0.0,
	"halftone": 0.0,           # shadows as a dot screen
	"halftone_px": 6.0,        # dot spacing, pixels at 1080 lines
	"split_mix": 0.0,
	"shadow_tint": Color(1, 1, 1),
	"highlight_tint": Color(1, 1, 1),
	"outline_tint": Color(1, 1, 1),
}

const STYLES := {
	REALISTIC: {},
	# Solarpunk: Ghibli-ish painted daylight. The references are flat-lit,
	# saturated greens and blues, soft shadows that stay coloured (never black),
	# clear distant air, thin dark lines on near things, foliage as painted
	# blobs. Numbers tuned by eye on Mount Vernon and Walton.
	SOLARPUNK: {
		"ambient_mult": 1.6,
		"fog_mult": 0.6,
		"aerial_mult": 0.85,
		"glow_int_mult": 1.5,
		"glow_threshold_mult": 0.8,
		"glow_bloom": 0.03,
		"adj_saturation": 1.1,
		"adj_contrast": 1.06,
		"adj_brightness": 1.03,
		"kuwahara_px": 3.0,
		"band_mix": 0.6,
		"band_stops": 1.2,
		"band_soft": 0.22,
		"light_compress": 0.35,
		"outline_mix": 0.8,
		"outline_px": 1.0,
		"outline_depth_t": 0.010,
		"outline_normal_t": 0.6,
		"outline_dark": 0.38,
		"outline_fade_start": 25.0,
		"outline_fade_end": 180.0,
		"outline_normals": 1.0,
		"saturation": 1.25,
		"vibrance": 0.25,
		"sky_saturation": 1.25,
		"sky_cyan": 0.25,
		"green_push": 0.7,
		"split_mix": 1.0,
		"shadow_tint": Color(0.86, 1.0, 1.0),
		"highlight_tint": Color(1.04, 1.0, 0.93),
		"outline_tint": Color(0.75, 0.85, 1.0),
	},
	# Storybook watercolor: wet washes on cold-press paper. A bigger, looser
	# brush than Solarpunk, little banding (washes blend), pale lifted
	# shadows that go violet, warm sepia line work on silhouettes only.
	WATERCOLOR: {
		"ambient_mult": 1.5,
		"fog_mult": 0.75,
		"aerial_mult": 0.8,
		"glow_int_mult": 1.2,
		"glow_bloom": 0.0,
		"adj_saturation": 1.05,
		"adj_contrast": 1.02,
		"adj_brightness": 1.08,
		"kuwahara_px": 4.5,
		"band_mix": 0.3,
		"band_stops": 1.6,
		"band_soft": 0.35,
		"light_compress": 0.45,
		"outline_mix": 0.5,
		"outline_px": 1.0,
		"outline_depth_t": 0.014,
		"outline_dark": 0.5,
		"outline_fade_start": 20.0,
		"outline_fade_end": 140.0,
		"outline_normals": 0.0,
		"saturation": 1.12,
		"vibrance": 0.35,
		"sky_saturation": 1.2,
		"sky_cyan": 0.15,
		"green_push": 0.4,
		"split_mix": 0.8,
		"shadow_tint": Color(0.94, 0.88, 1.1),
		"highlight_tint": Color(1.05, 1.0, 0.9),
		"outline_tint": Color(0.95, 0.72, 0.55),
		"lift": 0.05,
		"grain": 0.09,
		"vignette": 0.15,
		"paper_tint": Color(1.0, 0.96, 0.88),
		"paper_mix": 0.25,
	},
	# Ink & halftone: a printed comic. Hard light bands, thick black lines
	# with creases, near-monochrome duotone (ink-blue shadows, cream lights),
	# the dark band printed as a dot screen.
	INK: {
		"ambient_mult": 1.2,
		"fog_mult": 0.8,
		"adj_saturation": 0.95,
		"adj_contrast": 1.32,
		"kuwahara_px": 3.5,
		"band_mix": 1.0,
		"band_stops": 2.0,
		"band_soft": 0.05,
		"light_compress": 0.15,
		"outline_mix": 1.0,
		"outline_px": 1.4,
		"outline_depth_t": 0.008,
		"outline_normal_t": 0.45,
		"outline_dark": 0.04,
		"outline_fade_start": 40.0,
		"outline_fade_end": 320.0,
		"saturation": 0.28,
		"sky_saturation": 0.35,
		"split_mix": 1.0,
		"shadow_tint": Color(0.72, 0.84, 1.12),
		"highlight_tint": Color(1.1, 1.02, 0.84),
		"outline_tint": Color(0.6, 0.7, 1.0),
		"grain": 0.04,
		"vignette": 0.2,
		"paper_tint": Color(1.0, 0.97, 0.88),
		"paper_mix": 0.4,
		"halftone": 0.75,
		"halftone_px": 6.0,
	},
	# Cinematic: the blockbuster grade. Nothing painted or drawn: teal in the
	# shadows, orange in the lights, more contrast, bloom, vignette, grain.
	CINEMATIC: {
		"fog_mult": 1.15,
		"glow_int_mult": 1.35,
		"glow_threshold_mult": 0.85,
		"glow_bloom": 0.02,
		"adj_saturation": 1.04,
		"adj_contrast": 1.15,
		"saturation": 1.05,
		"vibrance": 0.1,
		"sky_saturation": 1.05,
		"sky_cyan": 0.3,
		"split_mix": 1.0,
		"shadow_tint": Color(0.7, 1.0, 1.18),
		"highlight_tint": Color(1.22, 0.97, 0.74),
		"grain": 0.03,
		"grain_film": 1.0,
		"vignette": 0.38,
	},
}

## Sub-controls: which keys each slider scales (0 = off, 1 = the style's own).
const OUTLINE_KEYS := ["outline_mix"]
const PAINTERLY_KEYS := ["kuwahara_px"]
const CEL_KEYS := ["band_mix", "light_compress", "halftone"]


static func has_style(id: String) -> bool:
	return STYLES.has(id)


static func label(id: String) -> String:
	return String(LABELS.get(id, id))


## The style's own numbers at full strength (IDENTITY filled in).
static func raw(id: String) -> Dictionary:
	var out := IDENTITY.duplicate()
	var s: Dictionary = STYLES.get(id, {})
	for k in s:
		out[k] = s[k]
	return out


## The numbers to render with: the style blended toward the identity by
## strength (0..1), then the outline / painterly / cel sub-controls (0..2,
## 1 = as the style has them) scale their own keys toward their identity.
static func resolve(id: String, strength: float = 1.0, outlines: float = 1.0,
		painterly: float = 1.0, cel: float = 1.0) -> Dictionary:
	var full := raw(id)
	var s := clampf(strength, 0.0, 1.0)
	var out := {}
	for k in IDENTITY:
		out[k] = _blend(IDENTITY[k], full[k], s)
	_scale_keys(out, OUTLINE_KEYS, outlines)
	_scale_keys(out, PAINTERLY_KEYS, painterly)
	_scale_keys(out, CEL_KEYS, cel)
	out["outline_mix"] = clampf(float(out["outline_mix"]), 0.0, 1.0)
	out["band_mix"] = clampf(float(out["band_mix"]), 0.0, 1.0)
	out["light_compress"] = clampf(float(out["light_compress"]), 0.0, 0.6)
	out["kuwahara_px"] = clampf(float(out["kuwahara_px"]), 0.0, 8.0)
	out["id"] = id if has_style(id) else REALISTIC
	out["post_on"] = needs_post(out)
	return out


## True when the post pass would change any pixel.
static func needs_post(p: Dictionary) -> bool:
	return float(p.get("kuwahara_px", 0.0)) >= 0.5 \
		or float(p.get("band_mix", 0.0)) > 0.001 \
		or float(p.get("light_compress", 0.0)) > 0.001 \
		or float(p.get("outline_mix", 0.0)) > 0.001 \
		or absf(float(p.get("saturation", 1.0)) - 1.0) > 0.001 \
		or float(p.get("vibrance", 0.0)) > 0.001 \
		or absf(float(p.get("sky_saturation", 1.0)) - 1.0) > 0.001 \
		or float(p.get("sky_cyan", 0.0)) > 0.001 		or float(p.get("green_push", 0.0)) > 0.001 \
		or float(p.get("lift", 0.0)) > 0.001 \
		or float(p.get("grain", 0.0)) > 0.001 \
		or float(p.get("vignette", 0.0)) > 0.001 \
		or float(p.get("paper_mix", 0.0)) > 0.001 \
		or float(p.get("halftone", 0.0)) > 0.001 \
		or float(p.get("split_mix", 0.0)) > 0.001


static func is_identity(p: Dictionary) -> bool:
	for k in IDENTITY:
		var a = IDENTITY[k]
		var b = p.get(k, a)
		if a is Color:
			if not (b as Color).is_equal_approx(a):
				return false
		elif absf(float(b) - float(a)) > 1e-6:
			return false
	return true


## Environment overlay, called by Main at the end of its environment update
## (and of _update_glow), after every other writer — so the multipliers act on
## freshly computed values. `which` = "env" | "glow".
static func apply_env(env: Environment, p: Dictionary, which: String = "env") -> void:
	if env == null:
		return
	if which == "glow":
		env.glow_intensity *= float(p.get("glow_int_mult", 1.0))
		env.glow_hdr_threshold *= float(p.get("glow_threshold_mult", 1.0))
		env.glow_bloom = float(p.get("glow_bloom", 0.0))
		return
	env.ambient_light_energy *= float(p.get("ambient_mult", 1.0))
	env.fog_density *= float(p.get("fog_mult", 1.0))
	env.fog_aerial_perspective = clampf(env.fog_aerial_perspective * float(p.get("aerial_mult", 1.0)), 0.0, 1.0)
	var sat := float(p.get("adj_saturation", 1.0))
	var con := float(p.get("adj_contrast", 1.0))
	var bri := float(p.get("adj_brightness", 1.0))
	var adj := absf(sat - 1.0) > 1e-4 or absf(con - 1.0) > 1e-4 or absf(bri - 1.0) > 1e-4
	env.adjustment_enabled = adj
	env.adjustment_saturation = sat
	env.adjustment_contrast = con
	env.adjustment_brightness = bri


## The 28 floats the effect's push constant carries after (size, mode, near):
## the layout RenderStyleEffect.SHADER expects, in order. Whether crease lines
## come from the normal buffer ("outline_normals") rides the mode instead.
static func post_floats(p: Dictionary, exposure: float) -> PackedFloat32Array:
	var st: Color = p["shadow_tint"]
	var hi: Color = p["highlight_tint"]
	var ot: Color = p["outline_tint"]
	return PackedFloat32Array([
		# p1
		float(p["band_mix"]), maxf(float(p["band_stops"]), 0.1), clampf(float(p["band_soft"]), 0.01, 0.5), float(p["light_compress"]),
		# p2 (kuwahara / outline pixel sizes are at 1080 lines; the effect scales them)
		float(p["kuwahara_px"]), float(p["outline_mix"]), float(p["outline_px"]), float(p["outline_dark"]),
		# p3
		float(p["outline_depth_t"]), float(p["outline_normal_t"]), float(p["outline_fade_start"]), maxf(float(p["outline_fade_end"]), float(p["outline_fade_start"]) + 1.0),
		# p4
		float(p["saturation"]), float(p["vibrance"]), float(p["sky_saturation"]), maxf(exposure, 0.01),
		# p5
		st.r, st.g, st.b, float(p["split_mix"]),
		# p6
		hi.r, hi.g, hi.b, float(p["sky_cyan"]),
		# p7
		ot.r, ot.g, ot.b, float(p["green_push"]),
	])


## The 12 floats of the effect's uniform buffer (std140, three vec4). The
## time slot (index 10) is filled by the effect on the render thread.
static func extra_floats(p: Dictionary) -> PackedFloat32Array:
	var pt: Color = p["paper_tint"]
	return PackedFloat32Array([
		float(p["lift"]), float(p["grain"]), float(p["grain_film"]), float(p["vignette"]),
		pt.r, pt.g, pt.b, float(p["paper_mix"]),
		float(p["halftone"]), maxf(float(p["halftone_px"]), 2.0), 0.0, 0.0,
	])


## Whether a sub-control slider does anything for this style (Lighting page).
static func has_sub_control(id: String, which: String) -> bool:
	var keys: Array = {"outlines": OUTLINE_KEYS, "painterly": PAINTERLY_KEYS, "cel": CEL_KEYS}.get(which, [])
	var st: Dictionary = STYLES.get(id, {})
	for k in keys:
		if st.has(k) and absf(float(st[k]) - float(IDENTITY[k])) > 1e-6:
			return true
	return false


static func _scale_keys(out: Dictionary, keys: Array, k: float) -> void:
	var m := clampf(k, 0.0, 2.0)
	for key in keys:
		var id_v := float(IDENTITY[key])
		out[key] = id_v + (float(out[key]) - id_v) * m


static func _blend(a, b, t: float):
	if a is Color:
		return (a as Color).lerp(b as Color, t)
	return lerpf(float(a), float(b), t)

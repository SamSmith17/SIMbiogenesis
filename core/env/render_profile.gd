class_name RenderProfile
extends RefCounted

## Renderer and shadow quality presets, as PURE data.
##
## These tables were inline in main.gd, mixed in with the code that applies them
## to the live viewport and the sun/moon lights. Splitting them out draws the
## boundary where it is actually useful: the mapping `quality level -> settings`
## is a pure function with no engine state, so it can be pinned by an offline
## selftest (core/env/render_profile_selftest.gd), while the *application* stays
## on Main where the nodes being configured live.
##
## Why it matters that these are pinned: project.godot only supplies the HIGH
## baseline, and main.gd overrides atlas size, soft-shadow quality and TAA at
## runtime from whichever preset is selected. Reading project.godot alone
## therefore tells you almost nothing about what the game actually renders with
## — a real source of confusion when auditing performance.

## Graphics presets. Indices are persisted in user settings, so their MEANING
## must not be reordered — append instead.
const QUALITY_LOW := 0
const QUALITY_MEDIUM := 1
const QUALITY_HIGH := 2

## Shared with PropRenderTuning's [props] section; ConfigFile preserves other
## sections on save.
const PERF_PREFS_CFG := "user://perf_prefs.cfg"


static func quality_name(quality: int) -> String:
	match quality:
		QUALITY_LOW: return "Low"
		QUALITY_MEDIUM: return "Medium"
		QUALITY_HIGH: return "High"
	return "High"


## Global renderer knobs for a graphics preset:
##   atlas_size    directional shadow atlas resolution
##   soft_quality  RenderingServer.ShadowQuality for directional + positional
##   taa           temporal AA (real under Forward+; the project's desktop
##                 renderer, since project.godot only overrides
##                 rendering_method.mobile)
## Unknown levels fall back to HIGH rather than returning empty — a bad saved
## index should degrade to "looks right", not to "renders with nothing set".
static func graphics_profile(quality: int) -> Dictionary:
	match quality:
		QUALITY_LOW:
			return {
				"atlas_size": 1024,
				"soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
				"taa": false,
			}
		QUALITY_MEDIUM:
			return {
				"atlas_size": 1536,
				"soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
				"taa": true,
			}
	# HIGH, and the fallback: matches the project.godot baseline.
	return {
		"atlas_size": 2048,
		"soft_quality": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"taa": true,
	}


## Directional-light shadow profile for a shadow-quality level (0..3).
##
## `moon_distance_scale` exists because the moon reuses the sun's profile at a
## reduced shadow distance — moonlight shadows are softer and much dimmer, so
## paying full cascade distance for them is waste.
##
## Returns {} for an unknown level, and callers treat empty as "leave the
## lights alone" — that is deliberate and different from graphics_profile's
## fallback: shadow settings are applied onto live lights, so doing nothing is
## safer than forcing a preset the caller did not ask for.
static func shadow_profile(shadow_quality: int) -> Dictionary:
	match shadow_quality:
		0:
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
				"max_distance": 90.0,
				"blur": 2.0,
				"bias": 0.085,
				"normal_bias": 3.4,
				"split_1": 0.15,
				"split_2": 0.4,
				"split_3": 0.7,
				"pancake": 24.0,
				"moon_distance_scale": 0.7,
			}
		1:
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
				"max_distance": 150.0,
				"blur": 1.2,
				"bias": 0.055,
				"normal_bias": 2.2,
				"split_1": 0.12,
				"split_2": 0.38,
				"split_3": 0.68,
				"pancake": 30.0,
				"moon_distance_scale": 0.9,
			}
		2:
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
				"max_distance": 230.0,
				"blur": 0.55,
				"bias": 0.03,
				"normal_bias": 1.0,
				"split_1": 0.08,
				"split_2": 0.25,
				"split_3": 0.58,
				"pancake": 40.0,
				"moon_distance_scale": 1.0,
			}
		3:
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
				"max_distance": 320.0,
				"blur": 0.22,
				"bias": 0.018,
				"normal_bias": 0.55,
				"split_1": 0.06,
				"split_2": 0.2,
				"split_3": 0.52,
				"pancake": 50.0,
				"moon_distance_scale": 1.15,
			}
	return {}


## Persisted 3D render scale. Kept here with the other render settings so there
## is one place that knows the config path and section.
static func load_render_scale(fallback: float) -> float:
	var cfg := ConfigFile.new()
	if cfg.load(PERF_PREFS_CFG) == OK:
		return float(cfg.get_value("render", "scale_3d", fallback))
	return fallback


static func save_render_scale(value: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PERF_PREFS_CFG)  # keep [props] and any other sections
	cfg.set_value("render", "scale_3d", value)
	cfg.save(PERF_PREFS_CFG)

extends Node
class_name StarSystem

## Consolidated star rendering system.
## Owns the star-map texture and its REGISTRATION, the look parameters, the
## reference-star markers, and every star-related shader push.
##
## Orientation is COMPUTED, never calibrated: each sky tick this pushes the
## local sidereal time plus the equatorial basis for the current latitude
## (StarSkyMath.equatorial_basis — pole / meridian / east vectors in world
## space) and sky.gdshader inverts that basis per pixel to get RA/Dec, then
## reads the texel through the map's registration (which RA sits at u = 0,
## which way RA runs, whether the NCP is the top row). The registration is
## DATA from the sidecar JSON next to the texture, written by
## tools/starmap_prepare.py from the bright stars it finds in the image.
##
## History, so nobody puts it back: the shader used to rotate the view about
## the pole by LST and then read the texture latitude off the rotated WORLD
## vector — the zenith as the texture pole, only right at latitude 90°. The
## RA/Dec "offset" and "flip" sliders that used to live here existed to fight
## that, and could only ever null it at one instant. They are gone; the
## computed reference-star markers (HOME) are how alignment is checked now.
## Pinned offline by core/astronomy/star_sky_selftest.gd.

# ==================== STAR TEXTURE ====================

@export_group("Star Texture")

## The equirectangular (plate carrée) star map in the EQUATORIAL frame.
## Changing this swaps the entire night sky star field; the sidecar JSON next
## to it (same basename, .json) supplies the registration.
@export var stars_texture : Texture2D :
	set(value):
		stars_texture = value
		_refresh_registration_for_texture()
		_push_texture()

# ==================== APPEARANCE ====================

@export_group("Appearance")

## Star brightness multiplier (maps to shader opacity).
@export_range(0.0, 3.0, 0.1) var stars_brightness : float = 1.0 :
	set(value):
		stars_brightness = value
		_push_params()

## Star twinkling intensity (atmospheric scintillation).
@export_range(0.0, 1.0, 0.05) var stars_twinkle : float = 0.3 :
	set(value):
		stars_twinkle = value
		_push_params()

## Horizon extinction - how much stars fade near the horizon.
@export_range(0.0, 1.0, 0.05) var stars_horizon_fade : float = 0.5 :
	set(value):
		stars_horizon_fade = value
		_push_params()

## Soft glow around star texture samples (0 = sharp Stellarium points).
@export_range(0.0, 1.0, 0.05) var stars_glow : float = 0.0 :
	set(value):
		stars_glow = value
		_push_params()

## Contrast curve on the map's luminance (pow). 2.2 was tuned to crush the old
## export's airglow noise; the prep tool black-floors the map now, and at 2.2 a
## 2nd-magnitude star (Polaris!) rendered below 0.1 and the Milky Way vanished.
@export_range(1.0, 4.0, 0.05) var stars_contrast : float = 1.4 :
	set(value):
		stars_contrast = value
		_push_params()

## Luminance below which the map reads as background (trims residual airglow;
## the prep tool already black-floors the export).
@export_range(0.0, 0.3, 0.005) var stars_background_cut : float = 0.02 :
	set(value):
		stars_background_cut = value
		_push_params()

## Long-exposure star-trail swirl mix (0 = off, 1 = full streak).
@export_range(0.0, 1.0, 0.05) var star_trails : float = 0.0 :
	set(value):
		star_trails = value
		_push_params()

@export_range(0.0, 1.0, 0.05) var star_trail_length : float = 0.35 :
	set(value):
		star_trail_length = value
		_push_params()

## -1 erodes every star disc by one texel (smaller, sharper points), +1 dilates.
@export_range(-1.0, 1.0, 0.05) var stars_point_size : float = 0.0 :
	set(value):
		stars_point_size = value
		_push_params()

## Star colour saturation (the tint is read off each disc's fringe; the core
## clips to white in the export).
@export_range(0.0, 3.0, 0.05) var stars_saturation : float = 1.5 :
	set(value):
		stars_saturation = value
		_push_params()

## How strongly a bright sky (moonlight, light pollution) washes out the faint
## stars and the Milky Way. 0 = stars ignore the sky.
@export_range(0.0, 1.0, 0.05) var stars_wash : float = 0.7 :
	set(value):
		stars_wash = value
		_push_params()

## Milky Way (the diffuse part of the map) gain and colour saturation.
@export_range(0.0, 4.0, 0.05) var milkyway_gain : float = 1.3 :
	set(value):
		milkyway_gain = value
		_push_params()

@export_range(0.0, 3.0, 0.05) var milkyway_saturation : float = 1.2 :
	set(value):
		milkyway_saturation = value
		_push_params()

## Tint multiplied into the Milky Way band (the export is blue-grey).
@export var milkyway_tint : Color = Color(1.0, 0.94, 0.88) :
	set(value):
		milkyway_tint = value
		_push_params()

# ==================== ZODIAC OVERLAY ====================

@export_group("Zodiac")

## Constellation overlay (assets/sky/zodiac_overlay_8k.png, built by
## tools/zodiac_overlay_export.py from Stellarium data in the star map's own
## registration). 0 = off, 1 = with the stars (night, or the analemma daylight
## reveal), 2 = always.
@export_range(0, 2, 1) var zodiac_mode : int = 0 :
	set(value):
		zodiac_mode = clampi(value, 0, 2)
		_push_params()

@export_range(0.0, 2.0, 0.05) var zodiac_opacity : float = 0.8 :
	set(value):
		zodiac_opacity = value
		_push_params()

@export var zodiac_show_lines : bool = true :
	set(value):
		zodiac_show_lines = value
		_push_params()

@export var zodiac_show_labels : bool = true :
	set(value):
		zodiac_show_labels = value
		_push_params()

## Ophiuchus: the ecliptic crosses it too (IAU boundaries), so astronomically
## the sun passes through 13 constellations. Off by default — the classical 12.
@export var zodiac_show_ophiuchus : bool = false :
	set(value):
		zodiac_show_ophiuchus = value
		_push_params()

## The J2000 ecliptic, computed in the shader (not baked into the overlay).
@export var zodiac_show_ecliptic : bool = true :
	set(value):
		zodiac_show_ecliptic = value
		_push_params()

const ZODIAC_TEXTURE := "res://assets/sky/zodiac_overlay_8k.png"
var _zodiac_texture : Texture2D = null

## Analemma "stars through daylight" amount, read from Main every sky tick
## (Main.analemma_star_reveal while analemma_mode is on, else 0). Transient —
## persisted by Main with the other analemma settings, never here.
var daylight_reveal : float = 0.0

## "standard" = the 8k map, "high" = the 16k map when it is shipped
## (assets/sky/starmap_equirect_16k.png, ~128 MiB of VRAM as BC7).
var texture_quality : String = "standard"

## When true, freeze LST so stars hold still relative to the camera (astro lock).
## Landscape / sun motion continue; useful for still night photography framing.
## Latitude changes still re-orient the basis — the lock is on TIME only.
var lock_camera_to_sky : bool = false
var _locked_lst : float = -1.0

# ==================== REFERENCE STAR CATALOG (J2000, degrees) ====================

const REFERENCE_STARS := {
	"polaris": {"ra": 37.954, "dec": 89.264, "name": "Polaris", "color": Color(0, 1, 1)},
	"dubhe": {"ra": 165.932, "dec": 61.751, "name": "Dubhe (Big Dipper)", "color": Color(0, 1, 0.8)},
	"merak": {"ra": 165.460, "dec": 56.382, "name": "Merak (Big Dipper)", "color": Color(0, 1, 0.8)},
	"betelgeuse": {"ra": 88.793, "dec": 7.407, "name": "Betelgeuse (Orion)", "color": Color(1, 0.5, 0)},
	"rigel": {"ra": 78.634, "dec": -8.202, "name": "Rigel (Orion)", "color": Color(0.5, 0.8, 1)},
	"bellatrix": {"ra": 81.283, "dec": 6.350, "name": "Bellatrix (Orion)", "color": Color(0.5, 0.8, 1)},
	"sirius": {"ra": 101.287, "dec": -16.716, "name": "Sirius", "color": Color(1, 1, 1)},
	"vega": {"ra": 279.235, "dec": 38.784, "name": "Vega", "color": Color(0.8, 0.9, 1)},
	"arcturus": {"ra": 213.915, "dec": 19.182, "name": "Arcturus", "color": Color(1, 0.8, 0.5)},
	"capella": {"ra": 79.172, "dec": 45.998, "name": "Capella", "color": Color(1, 1, 0.8)},
	"procyon": {"ra": 114.825, "dec": 5.225, "name": "Procyon", "color": Color(1, 1, 0.9)},
	"acrux": {"ra": 186.650, "dec": -63.099, "name": "Acrux (Southern Cross)", "color": Color(0.7, 0.8, 1)},
	"canopus": {"ra": 95.988, "dec": -52.696, "name": "Canopus", "color": Color(1, 1, 0.95)},
	"achernar": {"ra": 24.429, "dec": -57.237, "name": "Achernar", "color": Color(0.75, 0.85, 1)},
	"altair": {"ra": 297.696, "dec": 8.868, "name": "Altair", "color": Color(1, 1, 0.9)},
}

## The shader has 8 marker slots; these are the ones drawn.
const RENDERED_REFERENCE_STARS := ["polaris", "dubhe", "betelgeuse", "rigel", "sirius", "vega", "arcturus", "capella"]

# ==================== INTERNAL STATE ====================

const CONFIG_PATH := "user://star_calibration.cfg"
## Config keys older than this carried RA/Dec/flip/scale/drift "calibration"
## that no longer exists; a lower version is migrated (keys erased) on load.
const CALIBRATION_VERSION := 2
## `contrast` and `glow` are dropped too: their v1 values were tuned to hide the
## old export's noise and make the clean map's Milky Way and Polaris disappear.
const LEGACY_CONFIG_KEYS := ["north_offset", "declination_offset", "flip_vertical",
	"flip_horizontal", "scale", "drift_rate", "contrast", "glow"]
const STARMAPS_DIR := "user://starmaps/"
const DEFAULT_TEXTURE := "res://assets/sky/starmap_equirect_8k.png"
const DEFAULT_TEXTURE_HIGH := "res://assets/sky/starmap_equirect_16k.png"
const TEXTURE_QUALITIES := ["standard", "high"]

static func has_high_quality_texture() -> bool:
	return ResourceLoader.exists(DEFAULT_TEXTURE_HIGH)

## The shipped map for the current quality choice (falls back to the 8k map).
func default_texture_path() -> String:
	if texture_quality == "high" and has_high_quality_texture():
		return DEFAULT_TEXTURE_HIGH
	return DEFAULT_TEXTURE

var main_scene : Node = null
## Set after deferred `_find_main_scene()` finds the Main node. Main (`@tool`) must not call star
## updates before this is true — the node can briefly be a script placeholder during editor load.
var main_scene_ready : bool = false
var show_reference_stars : bool = false
var reference_star_directions : Dictionary = {}
var current_lst : float = 0.0
## Registration of the CURRENT texture (StarSkyMath.default_registration() shape).
var registration : Dictionary = StarSkyMath.default_registration()
## Source path the current texture was loaded from ("" when set from the editor).
var _texture_source_path : String = ""

var _legend : CanvasLayer = null
var _legend_label : Label = null

func _ready() -> void:
	main_scene_ready = false
	call_deferred("_find_main_scene")
	if not Engine.is_editor_hint():
		_load_calibration()

func _find_main_scene() -> void:
	main_scene = get_parent()
	if main_scene == null or not ("day_time" in main_scene):
		if is_inside_tree():
			var tree := get_tree()
			if tree:
				for child in tree.root.get_children():
					if "day_time" in child:
						main_scene = child
						break
	main_scene_ready = main_scene != null

# The HOME action toggles the computed reference-star markers (an InputMap
# action handled as an event: no per-frame polling, focus-guarded, rebindable).
func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not InputMap.has_action("toggle_star_calibration"):
		return
	if not event.is_action_pressed("toggle_star_calibration"):
		return
	if InputGuard.blocked(get_viewport()):
		return
	toggle_reference_stars()
	get_viewport().set_input_as_handled()

# ==================== SHADER UPDATES ====================

func _get_sky_material() -> ShaderMaterial:
	if main_scene == null or not is_instance_valid(main_scene):
		main_scene_ready = false
		return null
	var env = main_scene.get("environment")
	if env == null or not is_instance_valid(env):
		return null
	if env is WorldEnvironment:
		if env.environment == null or not is_instance_valid(env.environment):
			return null
		if env.environment.sky == null or not is_instance_valid(env.environment.sky):
			return null
		var mat : Material = env.environment.sky.sky_material
		if mat == null or not is_instance_valid(mat):
			return null
		if not (mat is ShaderMaterial):
			return null
		return mat as ShaderMaterial
	return null

func _push_texture() -> void:
	var mat := _get_sky_material()
	if mat and _zodiac_texture:
		mat.set_shader_parameter("zodiac_texture", _zodiac_texture)
	if mat and stars_texture:
		mat.set_shader_parameter("stars_texture", stars_texture)
		mat.set_shader_parameter("stars_texture_soft", stars_texture)
		_push_registration(mat)

func _push_registration(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("stars_ra_at_u0_deg", float(registration.get("ra_deg_at_u0", 0.0)))
	mat.set_shader_parameter("stars_ra_direction", -1.0 if int(registration.get("ra_direction", -1)) < 0 else 1.0)
	mat.set_shader_parameter("stars_north_up", 1.0 if bool(registration.get("north_up", true)) else 0.0)

func _push_look(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("stars_opacity", stars_brightness)
	mat.set_shader_parameter("stars_twinkle", stars_twinkle)
	mat.set_shader_parameter("stars_horizon_fade", stars_horizon_fade)
	mat.set_shader_parameter("stars_glow", stars_glow)
	mat.set_shader_parameter("stars_contrast", stars_contrast)
	mat.set_shader_parameter("stars_background_cut", stars_background_cut)
	mat.set_shader_parameter("star_trails", star_trails)
	mat.set_shader_parameter("star_trail_length", star_trail_length)
	mat.set_shader_parameter("stars_point_size", stars_point_size)
	mat.set_shader_parameter("stars_saturation", stars_saturation)
	mat.set_shader_parameter("stars_wash", stars_wash)
	mat.set_shader_parameter("milkyway_gain", milkyway_gain)
	mat.set_shader_parameter("milkyway_saturation", milkyway_saturation)
	mat.set_shader_parameter("milkyway_tint", milkyway_tint)
	mat.set_shader_parameter("stars_daylight_reveal", daylight_reveal)
	# Mode 0 without the texture too: a missing overlay must never draw black-on-nothing.
	var zmode := zodiac_mode if _zodiac_texture != null else 0
	mat.set_shader_parameter("zodiac_mode", float(zmode))
	mat.set_shader_parameter("zodiac_opacity", zodiac_opacity)
	mat.set_shader_parameter("zodiac_show_lines", 1.0 if zodiac_show_lines else 0.0)
	mat.set_shader_parameter("zodiac_show_labels", 1.0 if zodiac_show_labels else 0.0)
	mat.set_shader_parameter("zodiac_show_ophiuchus", 1.0 if zodiac_show_ophiuchus else 0.0)
	mat.set_shader_parameter("zodiac_show_ecliptic", 1.0 if zodiac_show_ecliptic else 0.0)
	# Neighbour taps in the shader are in TEXELS, so an 8k and a 16k map look alike.
	if stars_texture != null:
		var sz := stars_texture.get_size()
		if sz.x > 0.0 and sz.y > 0.0:
			mat.set_shader_parameter("stars_texel", Vector2(1.0 / sz.x, 1.0 / sz.y))

func _push_params() -> void:
	var mat := _get_sky_material()
	if mat == null:
		return
	_push_look(mat)
	_push_registration(mat)

## Called by main.gd each sky tick to update time/location-dependent star parameters.
func update_stars() -> void:
	var mat := _get_sky_material()
	if mat == null or main_scene == null or not is_instance_valid(main_scene):
		main_scene_ready = false
		return

	if stars_texture:
		mat.set_shader_parameter("stars_texture", stars_texture)
		mat.set_shader_parameter("stars_texture_soft", stars_texture)
	if _zodiac_texture:
		mat.set_shader_parameter("zodiac_texture", _zodiac_texture)
	daylight_reveal = 0.0
	if bool(main_scene.get("analemma_mode")):
		daylight_reveal = clampf(float(main_scene.get("analemma_star_reveal")), 0.0, 1.0)

	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = StarSkyMath.wrap360(main_scene.get_local_sidereal_time(jd_utc))
	if lock_camera_to_sky:
		if _locked_lst < 0.0:
			_locked_lst = lst
		lst = _locked_lst
	else:
		_locked_lst = -1.0
	current_lst = lst

	_push_look(mat)
	_push_registration(mat)
	mat.set_shader_parameter("stars_lst", lst)
	# Equatorial basis at the observer's latitude: the shader inverts this per
	# pixel. Pole elevation == latitude falls out of it (Polaris altitude).
	var basis : Dictionary = StarSkyMath.equatorial_basis(float(main_scene.latitude))
	mat.set_shader_parameter("stars_axis_pole", basis["pole"])
	mat.set_shader_parameter("stars_axis_meridian", basis["meridian"])
	mat.set_shader_parameter("stars_axis_east", basis["east"])


func set_star_trails(enabled: bool, length: float = -1.0) -> void:
	star_trails = 1.0 if enabled else 0.0
	if length >= 0.0:
		star_trail_length = clampf(length, 0.0, 1.0)


func set_lock_camera_to_sky(on: bool) -> void:
	lock_camera_to_sky = on
	if not on:
		_locked_lst = -1.0

## Called by main.gd each sky tick to update reference star marker positions.
func update_reference_stars() -> void:
	if main_scene == null or not is_instance_valid(main_scene):
		main_scene_ready = false
		return
	var mat := _get_sky_material()
	if mat == null:
		return

	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = main_scene.get_local_sidereal_time(jd_utc)
	var latitude : float = main_scene.latitude

	for star_name in RENDERED_REFERENCE_STARS:
		if star_name in REFERENCE_STARS:
			var star : Dictionary = REFERENCE_STARS[star_name]
			var horizontal := StarSkyMath.equatorial_to_horizontal(star.ra, star.dec, lst, latitude)
			var direction := StarSkyMath.direction_from_equatorial(star.ra, star.dec, lst, latitude)
			reference_star_directions[star_name] = {
				"direction": direction,
				"altitude": horizontal.altitude,
				"color": star.get("color", Color(0, 1, 1))
			}

	for i in range(min(8, RENDERED_REFERENCE_STARS.size())):
		var star_name : String = RENDERED_REFERENCE_STARS[i]
		var dir_param := "ref_star_direction_%d" % i
		var color_param := "ref_star_color_%d" % i
		var enabled_param := "ref_star_enabled_%d" % i

		if star_name in reference_star_directions:
			var data : Dictionary = reference_star_directions[star_name]
			mat.set_shader_parameter(dir_param, data.direction)
			mat.set_shader_parameter(color_param, Vector3(data.color.r, data.color.g, data.color.b))
			mat.set_shader_parameter(enabled_param, 1.0 if show_reference_stars and data.altitude > -5.0 else 0.0)
		else:
			mat.set_shader_parameter(dir_param, Vector3.UP)
			mat.set_shader_parameter(color_param, Vector3(0, 1, 1))
			mat.set_shader_parameter(enabled_param, 0.0)

	if show_reference_stars and _legend_label != null and is_instance_valid(_legend_label):
		_legend_label.text = _legend_text()

# ==================== REFERENCE-STAR MARKERS (HOME) ====================

func toggle_reference_stars() -> void:
	set_reference_stars_visible(not show_reference_stars)
	if show_reference_stars:
		debug_print_star_positions()

func set_reference_stars_visible(on: bool) -> void:
	show_reference_stars = on
	if on:
		_ensure_legend()
	if _legend != null and is_instance_valid(_legend):
		_legend.visible = on
	update_reference_stars()

## Kept as the old entry-point name for callers that toggled "calibration".
func toggle_calibration() -> void:
	toggle_reference_stars()

func _ensure_legend() -> void:
	if _legend != null and is_instance_valid(_legend):
		return
	_legend = CanvasLayer.new()
	_legend.name = "StarMarkerLegend"
	_legend.layer = 30
	_legend_label = Label.new()
	_legend_label.name = "Legend"
	_legend_label.position = Vector2(16, 16)
	_legend_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_legend_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_legend_label.add_theme_constant_override("shadow_offset_x", 1)
	_legend_label.add_theme_constant_override("shadow_offset_y", 1)
	_legend_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend.add_child(_legend_label)
	add_child(_legend)

func _legend_text() -> String:
	var lines : PackedStringArray = []
	lines.append("REFERENCE STARS (HOME) — computed positions; the texture stars should sit on the dots")
	var lst_h : float = current_lst / 15.0
	var polaris : Dictionary = get_reference_star_position("polaris")
	var pol_txt : String = ""
	if not polaris.is_empty():
		pol_txt = "  Polaris alt %.1f° (%s)" % [float(polaris.altitude), "up" if bool(polaris.visible) else "below horizon"]
	lines.append("LST %02d:%02d%s  ·  %s" % [int(lst_h), int(fmod(lst_h, 1.0) * 60.0), pol_txt, StarSkyMath.registration_summary(registration)])
	var swatches : PackedStringArray = []
	for star_name in RENDERED_REFERENCE_STARS:
		var star : Dictionary = REFERENCE_STARS[star_name]
		var d : Dictionary = reference_star_directions.get(star_name, {})
		var alt : float = float(d.get("altitude", -99.0))
		swatches.append("%s %s%.0f°" % [str(star.name).split(" ")[0], "" if alt >= 0.0 else "↓", alt])
	lines.append("  ".join(swatches))
	return "\n".join(lines)

# ==================== CONFIG ====================

func _load_calibration() -> void:
	var config := ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	var loaded_texture := false
	if err == OK:
		var version : int = int(config.get_value("stars", "calibration_version", 1))
		if version < CALIBRATION_VERSION:
			_migrate_config(config)
		stars_brightness = config.get_value("stars", "brightness", stars_brightness)
		stars_twinkle = config.get_value("stars", "twinkle", stars_twinkle)
		stars_horizon_fade = config.get_value("stars", "horizon_fade", stars_horizon_fade)
		stars_glow = config.get_value("stars", "glow", stars_glow)
		stars_contrast = config.get_value("stars", "contrast", stars_contrast)
		stars_background_cut = config.get_value("stars", "background_cut", stars_background_cut)
		star_trails = config.get_value("stars", "trails", star_trails)
		star_trail_length = config.get_value("stars", "trail_length", star_trail_length)
		lock_camera_to_sky = bool(config.get_value("stars", "lock_camera_to_sky", lock_camera_to_sky))
		stars_point_size = float(config.get_value("stars", "point_size", stars_point_size))
		stars_saturation = float(config.get_value("stars", "saturation", stars_saturation))
		stars_wash = float(config.get_value("stars", "wash", stars_wash))
		milkyway_gain = float(config.get_value("stars", "milkyway_gain", milkyway_gain))
		milkyway_saturation = float(config.get_value("stars", "milkyway_saturation", milkyway_saturation))
		var mwt: Variant = config.get_value("stars", "milkyway_tint", milkyway_tint)
		if mwt is Color:
			milkyway_tint = mwt
		zodiac_mode = int(config.get_value("stars", "zodiac_mode", zodiac_mode))
		zodiac_opacity = float(config.get_value("stars", "zodiac_opacity", zodiac_opacity))
		zodiac_show_lines = bool(config.get_value("stars", "zodiac_lines", zodiac_show_lines))
		zodiac_show_labels = bool(config.get_value("stars", "zodiac_labels", zodiac_show_labels))
		zodiac_show_ophiuchus = bool(config.get_value("stars", "zodiac_ophiuchus", zodiac_show_ophiuchus))
		zodiac_show_ecliptic = bool(config.get_value("stars", "zodiac_ecliptic", zodiac_show_ecliptic))
		var tq := str(config.get_value("stars", "texture_quality", texture_quality))
		texture_quality = tq if tq in TEXTURE_QUALITIES else "standard"
		var tex_path := str(config.get_value("stars", "texture_path", ""))
		if not tex_path.is_empty() and FileAccess.file_exists(tex_path):
			loaded_texture = _load_texture_from_file(tex_path)
	if not loaded_texture:
		_load_default_texture()
	if ResourceLoader.exists(ZODIAC_TEXTURE):
		_zodiac_texture = load(ZODIAC_TEXTURE) as Texture2D
	_push_texture()
	_push_params()

func _load_default_texture() -> void:
	var path := default_texture_path()
	if ResourceLoader.exists(path):
		_texture_source_path = path
		stars_texture = load(path) as Texture2D

## Switch between the shipped 8k and 16k maps (a player upload stays in force
## until "Reset texture"). Persisted; the UI only offers "high" when the 16k
## file exists.
func set_texture_quality(quality: String) -> void:
	if quality not in TEXTURE_QUALITIES:
		quality = "standard"
	texture_quality = quality
	if _stored_texture_path().is_empty():
		_load_default_texture()
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("stars", "calibration_version", CALIBRATION_VERSION)
	cfg.set_value("stars", "texture_quality", texture_quality)
	cfg.save(CONFIG_PATH)

## v1 -> v2: the RA/Dec/flip/scale/drift keys described a workaround for a
## shader bug that no longer exists, and an uploaded copy of the old GUI-baked
## map cannot be right without them — so the upload pointer goes too.
func _migrate_config(config: ConfigFile) -> void:
	for key in LEGACY_CONFIG_KEYS:
		if config.has_section_key("stars", key):
			config.erase_section_key("stars", key)
	if config.has_section_key("stars", "texture_path"):
		config.erase_section_key("stars", "texture_path")
	config.set_value("stars", "calibration_version", CALIBRATION_VERSION)
	config.save(CONFIG_PATH)

func save_calibration() -> void:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value("stars", "calibration_version", CALIBRATION_VERSION)
	config.set_value("stars", "brightness", stars_brightness)
	config.set_value("stars", "twinkle", stars_twinkle)
	config.set_value("stars", "horizon_fade", stars_horizon_fade)
	config.set_value("stars", "glow", stars_glow)
	config.set_value("stars", "contrast", stars_contrast)
	config.set_value("stars", "background_cut", stars_background_cut)
	config.set_value("stars", "trails", star_trails)
	config.set_value("stars", "trail_length", star_trail_length)
	config.set_value("stars", "lock_camera_to_sky", lock_camera_to_sky)
	config.set_value("stars", "point_size", stars_point_size)
	config.set_value("stars", "saturation", stars_saturation)
	config.set_value("stars", "wash", stars_wash)
	config.set_value("stars", "milkyway_gain", milkyway_gain)
	config.set_value("stars", "milkyway_saturation", milkyway_saturation)
	config.set_value("stars", "milkyway_tint", milkyway_tint)
	config.set_value("stars", "texture_quality", texture_quality)
	config.set_value("stars", "zodiac_mode", zodiac_mode)
	config.set_value("stars", "zodiac_opacity", zodiac_opacity)
	config.set_value("stars", "zodiac_lines", zodiac_show_lines)
	config.set_value("stars", "zodiac_labels", zodiac_show_labels)
	config.set_value("stars", "zodiac_ophiuchus", zodiac_show_ophiuchus)
	config.set_value("stars", "zodiac_ecliptic", zodiac_show_ecliptic)
	var tex_path := _stored_texture_path()
	if not tex_path.is_empty():
		config.set_value("stars", "texture_path", tex_path)
	config.save(CONFIG_PATH)

func get_settings() -> Dictionary:
	return {
		"stars_brightness": stars_brightness,
		"stars_twinkle": stars_twinkle,
		"stars_horizon_fade": stars_horizon_fade,
		"stars_glow": stars_glow,
		"stars_contrast": stars_contrast,
		"stars_background_cut": stars_background_cut,
		"star_trails": star_trails,
		"star_trail_length": star_trail_length,
		"lock_camera_to_sky": lock_camera_to_sky,
		"stars_point_size": stars_point_size,
		"stars_saturation": stars_saturation,
		"stars_wash": stars_wash,
		"milkyway_gain": milkyway_gain,
		"milkyway_saturation": milkyway_saturation,
		"milkyway_tint": milkyway_tint,
		"texture_quality": texture_quality,
		"zodiac_mode": zodiac_mode,
		"zodiac_opacity": zodiac_opacity,
		"zodiac_show_lines": zodiac_show_lines,
		"zodiac_show_labels": zodiac_show_labels,
		"zodiac_show_ophiuchus": zodiac_show_ophiuchus,
		"zodiac_show_ecliptic": zodiac_show_ecliptic,
		"zodiac_available": _zodiac_texture != null,
		"texture_quality_high_available": has_high_quality_texture(),
		"texture_path": _stored_texture_path(),
		"registration_summary": StarSkyMath.registration_summary(registration),
	}

func apply_settings(settings: Dictionary) -> void:
	if settings.has("stars_brightness"):
		stars_brightness = float(settings["stars_brightness"])
	if settings.has("stars_twinkle"):
		stars_twinkle = float(settings["stars_twinkle"])
	if settings.has("stars_horizon_fade"):
		stars_horizon_fade = float(settings["stars_horizon_fade"])
	if settings.has("stars_glow"):
		stars_glow = float(settings["stars_glow"])
	if settings.has("stars_contrast"):
		stars_contrast = float(settings["stars_contrast"])
	if settings.has("stars_background_cut"):
		stars_background_cut = float(settings["stars_background_cut"])
	if settings.has("star_trails"):
		star_trails = float(settings["star_trails"])
	if settings.has("star_trail_length"):
		star_trail_length = float(settings["star_trail_length"])
	if settings.has("lock_camera_to_sky"):
		set_lock_camera_to_sky(bool(settings["lock_camera_to_sky"]))
	if settings.has("stars_point_size"):
		stars_point_size = float(settings["stars_point_size"])
	if settings.has("stars_saturation"):
		stars_saturation = float(settings["stars_saturation"])
	if settings.has("stars_wash"):
		stars_wash = float(settings["stars_wash"])
	if settings.has("milkyway_gain"):
		milkyway_gain = float(settings["milkyway_gain"])
	if settings.has("milkyway_saturation"):
		milkyway_saturation = float(settings["milkyway_saturation"])
	if settings.has("milkyway_tint") and settings["milkyway_tint"] is Color:
		milkyway_tint = settings["milkyway_tint"]
	if settings.has("texture_quality"):
		set_texture_quality(str(settings["texture_quality"]))
	if settings.has("zodiac_mode"):
		zodiac_mode = int(settings["zodiac_mode"])
	if settings.has("zodiac_opacity"):
		zodiac_opacity = float(settings["zodiac_opacity"])
	for key in ["zodiac_show_lines", "zodiac_show_labels", "zodiac_show_ophiuchus", "zodiac_show_ecliptic"]:
		if settings.has(key):
			set(key, bool(settings[key]))

# ==================== TEXTURE SWAP ====================

## Copy a player-supplied star map (and its sidecar, when one sits next to it)
## into user://starmaps/ and switch to it. Without a sidecar the plate-carrée
## defaults are assumed and the settings label says so.
func set_texture_from_path(source_path: String) -> bool:
	if source_path.is_empty():
		return false
	var img := Image.new()
	var load_err := img.load(source_path)
	if load_err != OK:
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STARMAPS_DIR))
	var ext := source_path.get_extension()
	if ext.is_empty():
		ext = "png"
	var dest := STARMAPS_DIR + "starmap." + ext
	var save_err: Error
	if ext.to_lower() == "png":
		save_err = img.save_png(dest)
	else:
		save_err = img.save_jpg(dest)
	if save_err != OK:
		# Fallback: try png
		dest = STARMAPS_DIR + "starmap.png"
		save_err = img.save_png(dest)
	if save_err != OK:
		return false
	# Sidecar travels with the image; a stale one from a previous upload must not.
	var dest_json := StarSkyMath.sidecar_path_for(dest)
	if FileAccess.file_exists(dest_json):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dest_json))
	var src_json := StarSkyMath.sidecar_path_for(source_path)
	if FileAccess.file_exists(src_json):
		var f := FileAccess.open(src_json, FileAccess.READ)
		if f != null:
			var txt := f.get_as_text()
			f.close()
			var o := FileAccess.open(dest_json, FileAccess.WRITE)
			if o != null:
				o.store_string(txt)
				o.close()
	return _load_texture_from_file(dest)

func reset_texture_to_default() -> void:
	_load_default_texture()
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		cfg.erase_section_key("stars", "texture_path")
		cfg.save(CONFIG_PATH)

func _stored_texture_path() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	return str(cfg.get_value("stars", "texture_path", ""))

func _load_texture_from_file(path: String) -> bool:
	var img := Image.new()
	if img.load(path) != OK:
		return false
	_texture_source_path = path
	stars_texture = ImageTexture.create_from_image(img)
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("stars", "calibration_version", CALIBRATION_VERSION)
	cfg.set_value("stars", "texture_path", path)
	cfg.save(CONFIG_PATH)
	return true

## Re-read the sidecar for whatever the texture now is. An editor-assigned
## texture has a resource_path; a runtime ImageTexture carries none, so the
## path recorded by the loader is used instead.
func _refresh_registration_for_texture() -> void:
	var path : String = _texture_source_path
	if stars_texture != null and not stars_texture.resource_path.is_empty():
		path = stars_texture.resource_path
	registration = StarSkyMath.load_registration(path) if not path.is_empty() else StarSkyMath.default_registration()

func registration_summary() -> String:
	return StarSkyMath.registration_summary(registration)

# ==================== REFERENCE STAR QUERIES ====================

func get_reference_star_position(star_name: String) -> Dictionary:
	if star_name not in REFERENCE_STARS or main_scene == null or not is_instance_valid(main_scene):
		return {}
	var star : Dictionary = REFERENCE_STARS[star_name]
	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = main_scene.get_local_sidereal_time(jd_utc)
	var latitude : float = main_scene.latitude
	var horizontal := StarSkyMath.equatorial_to_horizontal(star.ra, star.dec, lst, latitude)
	var direction := StarSkyMath.direction_from_equatorial(star.ra, star.dec, lst, latitude)
	return {
		"name": star.name,
		"ra": star.ra,
		"dec": star.dec,
		"altitude": horizontal.altitude,
		"azimuth": horizontal.azimuth,
		"direction": direction,
		"visible": horizontal.altitude > 0.0
	}

func get_all_reference_star_positions() -> Dictionary:
	var result := {}
	for star_name in REFERENCE_STARS.keys():
		result[star_name] = get_reference_star_position(star_name)
	return result

func debug_print_star_positions() -> void:
	if main_scene == null or not is_instance_valid(main_scene):
		return
	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = main_scene.get_local_sidereal_time(jd_utc)
	print("[StarSystem] reference stars — lat %.4f lon %.4f  JD(UTC) %.5f  LST %.3f°  |  %s" % [
		float(main_scene.latitude), float(main_scene.longitude), jd_utc, lst,
		StarSkyMath.registration_summary(registration)])
	print("  %-22s %9s %9s %9s %9s  %s" % ["star", "RA°", "Dec°", "alt°", "az°", "status"])
	for star_name in REFERENCE_STARS.keys():
		var p : Dictionary = get_reference_star_position(star_name)
		if p.is_empty():
			continue
		print("  %-22s %9.3f %9.3f %9.3f %9.3f  %s" % [str(p.name), float(p.ra), float(p.dec),
			float(p.altitude), float(p.azimuth), "up" if bool(p.visible) else "below horizon"])

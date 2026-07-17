extends Node
class_name StarSystem

## Consolidated star rendering system.
## Manages the starmap texture, star field parameters, reference star calibration markers,
## and all star-related shader updates. Replaces scattered star logic from main.gd and planets.gd.

# ==================== STAR TEXTURE ====================

@export_group("Star Texture")

## The equirectangular starmap texture (e.g. exported from Stellarium).
## Changing this swaps the entire night sky star field.
@export var stars_texture : Texture2D :
	set(value):
		stars_texture = value
		_push_texture()

# ==================== ALIGNMENT ====================

@export_group("Alignment")

## Horizontal offset to align the star field (Right Ascension, degrees).
## Adjust until constellations appear in correct positions.
@export_range(-360.0, 360.0, 0.1) var stars_north_offset : float = 0.0 :
	set(value):
		stars_north_offset = value
		_push_params()

## Vertical offset to correct pole alignment (Declination, degrees).
@export_range(-180.0, 180.0, 0.1) var stars_declination_offset : float = 0.0 :
	set(value):
		stars_declination_offset = value
		_push_params()

## Flip the vertical axis of the starmap (for maps with NCP at bottom).
@export var stars_flip_vertical : bool = false :
	set(value):
		stars_flip_vertical = value
		_push_params()

## Flip the horizontal axis of the starmap (if stars move backwards).
@export var stars_flip_horizontal : bool = false :
	set(value):
		stars_flip_horizontal = value
		_push_params()

# ==================== APPEARANCE ====================

@export_group("Appearance")

## Star brightness multiplier (maps to shader opacity).
@export_range(0.0, 3.0, 0.1) var stars_brightness : float = 1.0 :
	set(value):
		stars_brightness = value
		_push_params()

## Star field scale (smaller = see more stars, larger = zoom in).
@export_range(0.5, 2.0, 0.05) var stars_scale : float = 1.0 :
	set(value):
		stars_scale = value
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

## Contrast for sharp star cores (higher cuts soft airglow further).
@export_range(1.0, 4.0, 0.05) var stars_contrast : float = 2.2 :
	set(value):
		stars_contrast = value
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

## When true, freeze LST so stars hold still relative to the camera (astro lock).
## Landscape / sun motion continue; useful for still night photography framing.
var lock_camera_to_sky : bool = false
var _locked_lst : float = -1.0

## Star drift rate relative to moon (0 = locked, 1 = realistic ~13 deg/day).
@export_range(0.0, 20.0, 0.5) var stars_drift_rate : float = 2.0

# ==================== REFERENCE STAR CATALOG ====================

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
}

const RENDERED_REFERENCE_STARS := ["polaris", "dubhe", "betelgeuse", "rigel", "sirius", "vega", "arcturus", "capella"]

# ==================== INTERNAL STATE ====================

const CONFIG_PATH := "user://star_calibration.cfg"
const STARMAPS_DIR := "user://starmaps/"
const DEFAULT_TEXTURE := "res://stellarium_starmap.png"
const HOURS_IN_DAY : float = 24.0

var main_scene : Node = null
## Set after deferred `_find_main_scene()` finds the Main node. Main (`@tool`) must not call star
## updates before this is true — the node can briefly be a script placeholder during editor load.
var main_scene_ready : bool = false
var show_reference_stars : bool = false
var reference_star_directions : Dictionary = {}
var current_lst : float = 0.0

var _calibration_ui : CanvasLayer = null
var _toggle_cooldown : float = 0.0

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

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_toggle_cooldown -= delta
	if Input.is_key_pressed(KEY_HOME) and _toggle_cooldown <= 0.0:
		toggle_calibration()
		_toggle_cooldown = 0.5

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
	if mat and stars_texture:
		mat.set_shader_parameter("stars_texture", stars_texture)

func _push_params() -> void:
	var mat := _get_sky_material()
	if mat == null:
		return
	mat.set_shader_parameter("stars_north_offset", stars_north_offset)
	mat.set_shader_parameter("stars_declination_offset", stars_declination_offset)
	mat.set_shader_parameter("stars_flip_vertical", 1.0 if stars_flip_vertical else 0.0)
	mat.set_shader_parameter("stars_flip_horizontal", 1.0 if stars_flip_horizontal else 0.0)
	mat.set_shader_parameter("stars_opacity", stars_brightness)
	mat.set_shader_parameter("stars_scale", stars_scale)
	mat.set_shader_parameter("stars_twinkle", stars_twinkle)
	mat.set_shader_parameter("stars_horizon_fade", stars_horizon_fade)
	mat.set_shader_parameter("stars_glow", stars_glow)
	mat.set_shader_parameter("stars_contrast", stars_contrast)
	mat.set_shader_parameter("star_trails", star_trails)
	mat.set_shader_parameter("star_trail_length", star_trail_length)

## Called by main.gd each frame to update time-dependent star parameters.
func update_stars() -> void:
	var mat := _get_sky_material()
	if mat == null or main_scene == null or not is_instance_valid(main_scene):
		main_scene_ready = false
		return

	if stars_texture:
		mat.set_shader_parameter("stars_texture", stars_texture)

	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = main_scene.get_local_sidereal_time(jd_utc)
	while lst < 0.0:
		lst += 360.0
	while lst >= 360.0:
		lst -= 360.0
	if lock_camera_to_sky:
		if _locked_lst < 0.0:
			_locked_lst = lst
		lst = _locked_lst
	else:
		_locked_lst = -1.0
	current_lst = lst

	mat.set_shader_parameter("stars_north_offset", stars_north_offset)
	mat.set_shader_parameter("stars_lst", lst)
	mat.set_shader_parameter("stars_declination_offset", stars_declination_offset)
	mat.set_shader_parameter("stars_flip_vertical", 1.0 if stars_flip_vertical else 0.0)
	mat.set_shader_parameter("stars_flip_horizontal", 1.0 if stars_flip_horizontal else 0.0)
	mat.set_shader_parameter("stars_opacity", stars_brightness)
	mat.set_shader_parameter("stars_scale", stars_scale)
	mat.set_shader_parameter("stars_twinkle", stars_twinkle)
	mat.set_shader_parameter("stars_horizon_fade", stars_horizon_fade)
	mat.set_shader_parameter("stars_glow", stars_glow)
	mat.set_shader_parameter("stars_contrast", stars_contrast)
	mat.set_shader_parameter("star_trails", star_trails)
	mat.set_shader_parameter("star_trail_length", star_trail_length)
	# North celestial pole elevation equals geographic latitude (Polaris altitude).
	mat.set_shader_parameter("celestial_pole_elevation", main_scene.latitude)

	var star_angle : float = _get_rotation_angle()
	mat.set_shader_parameter("star_rotation_angle", star_angle)


func set_star_trails(enabled: bool, length: float = -1.0) -> void:
	star_trails = 1.0 if enabled else 0.0
	if length >= 0.0:
		star_trail_length = clampf(length, 0.0, 1.0)


func set_lock_camera_to_sky(on: bool) -> void:
	lock_camera_to_sky = on
	if not on:
		_locked_lst = -1.0

## Called by main.gd each frame to update reference star marker positions.
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
			var horizontal := _equatorial_to_horizontal(star.ra, star.dec, lst, latitude)
			var direction := _horizontal_to_direction(horizontal.altitude, horizontal.azimuth)
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

# ==================== STAR ROTATION ====================

func _get_rotation_angle() -> float:
	if main_scene == null or not is_instance_valid(main_scene):
		return 0.0
	var day_of_year : int = main_scene.day_of_year if "day_of_year" in main_scene else 1
	var year : int = main_scene.year if "year" in main_scene else 2024
	var day_time : float = main_scene.day_time if "day_time" in main_scene else 12.0

	var days_elapsed : float = float(day_of_year - 1) + float(year - 2024) * 365.25
	var total_hours : float = days_elapsed * HOURS_IN_DAY + day_time
	var base_degrees : float = total_hours * 15.0
	var drift_degrees : float = days_elapsed * 13.0 * stars_drift_rate
	var star_degrees : float = base_degrees + drift_degrees
	return deg_to_rad(fmod(star_degrees, 360.0))

# ==================== CALIBRATION ====================

func toggle_calibration() -> void:
	show_reference_stars = not show_reference_stars
	if show_reference_stars:
		debug_print_star_positions()
	else:
		pass

	if _calibration_ui == null:
		var ui_scene := load("res://scenes/ui/star_calibration_ui.tscn") as PackedScene
		if ui_scene != null:
			_calibration_ui = ui_scene.instantiate()
			add_child(_calibration_ui)
			_calibration_ui.show_ui()
	else:
		if _calibration_ui.is_visible:
			_calibration_ui.hide_ui()
		else:
			_calibration_ui.show_ui()

func _load_calibration() -> void:
	var config := ConfigFile.new()
	var err := config.load(CONFIG_PATH)
	if err == OK:
		stars_north_offset = config.get_value("stars", "north_offset", stars_north_offset)
		stars_declination_offset = config.get_value("stars", "declination_offset", stars_declination_offset)
		stars_brightness = config.get_value("stars", "brightness", stars_brightness)
		stars_flip_vertical = config.get_value("stars", "flip_vertical", stars_flip_vertical)
		stars_flip_horizontal = config.get_value("stars", "flip_horizontal", stars_flip_horizontal)
		stars_scale = config.get_value("stars", "scale", stars_scale)
		stars_twinkle = config.get_value("stars", "twinkle", stars_twinkle)
		stars_horizon_fade = config.get_value("stars", "horizon_fade", stars_horizon_fade)
		stars_drift_rate = config.get_value("stars", "drift_rate", stars_drift_rate)
		stars_glow = config.get_value("stars", "glow", stars_glow)
		stars_contrast = config.get_value("stars", "contrast", stars_contrast)
		star_trails = config.get_value("stars", "trails", star_trails)
		star_trail_length = config.get_value("stars", "trail_length", star_trail_length)
		lock_camera_to_sky = bool(config.get_value("stars", "lock_camera_to_sky", lock_camera_to_sky))
		var tex_path := str(config.get_value("stars", "texture_path", ""))
		if not tex_path.is_empty() and FileAccess.file_exists(tex_path):
			_load_texture_from_file(tex_path)
	elif ResourceLoader.exists(DEFAULT_TEXTURE):
		stars_texture = load(DEFAULT_TEXTURE) as Texture2D
	_push_params()

func save_calibration() -> void:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value("stars", "north_offset", stars_north_offset)
	config.set_value("stars", "declination_offset", stars_declination_offset)
	config.set_value("stars", "brightness", stars_brightness)
	config.set_value("stars", "flip_vertical", stars_flip_vertical)
	config.set_value("stars", "flip_horizontal", stars_flip_horizontal)
	config.set_value("stars", "scale", stars_scale)
	config.set_value("stars", "twinkle", stars_twinkle)
	config.set_value("stars", "horizon_fade", stars_horizon_fade)
	config.set_value("stars", "drift_rate", stars_drift_rate)
	config.set_value("stars", "glow", stars_glow)
	config.set_value("stars", "contrast", stars_contrast)
	config.set_value("stars", "trails", star_trails)
	config.set_value("stars", "trail_length", star_trail_length)
	config.set_value("stars", "lock_camera_to_sky", lock_camera_to_sky)
	var tex_path := _stored_texture_path()
	if not tex_path.is_empty():
		config.set_value("stars", "texture_path", tex_path)
	config.save(CONFIG_PATH)

func get_settings() -> Dictionary:
	return {
		"stars_north_offset": stars_north_offset,
		"stars_declination_offset": stars_declination_offset,
		"stars_brightness": stars_brightness,
		"stars_flip_vertical": stars_flip_vertical,
		"stars_flip_horizontal": stars_flip_horizontal,
		"stars_scale": stars_scale,
		"stars_twinkle": stars_twinkle,
		"stars_horizon_fade": stars_horizon_fade,
		"stars_drift_rate": stars_drift_rate,
		"stars_glow": stars_glow,
		"stars_contrast": stars_contrast,
		"star_trails": star_trails,
		"star_trail_length": star_trail_length,
		"lock_camera_to_sky": lock_camera_to_sky,
		"texture_path": _stored_texture_path(),
	}

func apply_settings(settings: Dictionary) -> void:
	if settings.has("stars_north_offset"):
		stars_north_offset = float(settings["stars_north_offset"])
	if settings.has("stars_declination_offset"):
		stars_declination_offset = float(settings["stars_declination_offset"])
	if settings.has("stars_brightness"):
		stars_brightness = float(settings["stars_brightness"])
	if settings.has("stars_flip_vertical"):
		stars_flip_vertical = bool(settings["stars_flip_vertical"])
	if settings.has("stars_flip_horizontal"):
		stars_flip_horizontal = bool(settings["stars_flip_horizontal"])
	if settings.has("stars_scale"):
		stars_scale = float(settings["stars_scale"])
	if settings.has("stars_twinkle"):
		stars_twinkle = float(settings["stars_twinkle"])
	if settings.has("stars_horizon_fade"):
		stars_horizon_fade = float(settings["stars_horizon_fade"])
	if settings.has("stars_drift_rate"):
		stars_drift_rate = float(settings["stars_drift_rate"])
	if settings.has("stars_glow"):
		stars_glow = float(settings["stars_glow"])
	if settings.has("stars_contrast"):
		stars_contrast = float(settings["stars_contrast"])
	if settings.has("star_trails"):
		star_trails = float(settings["star_trails"])
	if settings.has("star_trail_length"):
		star_trail_length = float(settings["star_trail_length"])
	if settings.has("lock_camera_to_sky"):
		set_lock_camera_to_sky(bool(settings["lock_camera_to_sky"]))

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
	return _load_texture_from_file(dest)

func reset_texture_to_default() -> void:
	if ResourceLoader.exists(DEFAULT_TEXTURE):
		stars_texture = load(DEFAULT_TEXTURE) as Texture2D
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
	stars_texture = ImageTexture.create_from_image(img)
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("stars", "texture_path", path)
	cfg.save(CONFIG_PATH)
	return true

# ==================== REFERENCE STAR QUERIES ====================

func get_reference_star_position(star_name: String) -> Dictionary:
	if star_name not in REFERENCE_STARS or main_scene == null or not is_instance_valid(main_scene):
		return {}
	var star : Dictionary = REFERENCE_STARS[star_name]
	var jd_utc : float = main_scene.get_julian_day_utc()
	var lst : float = main_scene.get_local_sidereal_time(jd_utc)
	var latitude : float = main_scene.latitude
	var horizontal := _equatorial_to_horizontal(star.ra, star.dec, lst, latitude)
	var direction := _horizontal_to_direction(horizontal.altitude, horizontal.azimuth)
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
	pass

# ==================== COORDINATE CONVERSION ====================

func _equatorial_to_horizontal(ra: float, dec: float, lst: float, latitude: float) -> Dictionary:
	var ha : float = lst - ra
	while ha > 180.0:
		ha -= 360.0
	while ha < -180.0:
		ha += 360.0
	var ha_rad : float = deg_to_rad(ha)
	var dec_rad : float = deg_to_rad(dec)
	var lat_rad : float = deg_to_rad(latitude)
	var sin_alt : float = sin(lat_rad) * sin(dec_rad) + cos(lat_rad) * cos(dec_rad) * cos(ha_rad)
	sin_alt = clamp(sin_alt, -1.0, 1.0)
	var altitude : float = asin(sin_alt)
	var cos_alt : float = cos(altitude)
	var cos_az : float = 0.0
	if abs(cos_alt) > 0.0001 and abs(cos(lat_rad)) > 0.0001:
		cos_az = (sin(dec_rad) - sin(lat_rad) * sin_alt) / (cos(lat_rad) * cos_alt)
		cos_az = clamp(cos_az, -1.0, 1.0)
	var azimuth : float = acos(cos_az)
	if sin(ha_rad) > 0.0:
		azimuth = TAU - azimuth
	return {"altitude": rad_to_deg(altitude), "azimuth": rad_to_deg(azimuth)}

func _horizontal_to_direction(altitude: float, azimuth: float) -> Vector3:
	var alt_rad : float = deg_to_rad(altitude)
	var az_rad : float = deg_to_rad(azimuth)
	var cos_alt : float = cos(alt_rad)
	return Vector3(cos_alt * sin(az_rad), sin(alt_rad), -cos_alt * cos(az_rad)).normalized()

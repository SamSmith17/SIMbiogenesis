class_name GroundFogLayer
extends Node3D

## The microclimate's ground fog, drawn as ONE FogVolume box that follows the
## camera horizontally and spans the valley vertically. The shader
## (ground_fog.gdshader) caps the fog at an absolute world height, so standing
## in it you lose the tree line; from the drone the valley reads as filled
## while the ridges stand clear.
##
## FogVolumes only draw inside the volumetric-fog pass, so main.gd forces that
## pass on while the fog is present — the same reasoning as the dust wall: a
## valley fog that only appears for players who happened to tick "volumetric
## fog" is not a feature. Owned and fed by main.gd (_update_ground_fog).

const SHADER := preload("res://core/env/ground_fog.gdshader")
## Horizontal half-size of the box. Beyond the froxel range the volume is not
## sampled anyway; past that the exponential distance fog carries the haze.
const HALF_XZ_M := 1400.0
const BELOW_FLOOR_M := 60.0
## Emission per unit of DaylightModel.sky_light — tuned against the Walton
## capture so a daytime fog reads as bright grey.
const SKY_EMISSION_GAIN := 0.9

## 0..1 how warm/orange the sun's beam is (set by main.gd); 0 at midday.
var sun_warmth := 0.0
var _vol: FogVolume
var _mat: ShaderMaterial
var _drift := Vector3.ZERO


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_vol = FogVolume.new()
	_vol.name = "GroundFog"
	_vol.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_vol.material = _mat
	add_child(_vol)
	visible = false


## `st` is Microclimate.current(); `cam_pos` the active camera; `wind_xz` the
## world wind (m/s, direction the air moves) for the slow noise drift.
func update_from(st: Dictionary, cam_pos: Vector3, wind_xz: Vector2, delta: float,
		night_amount: float, sky_light: float = 1.0) -> void:
	var sigma := float(st.get("fog_sigma", 0.0))
	if sigma <= 1e-5 or not is_finite(sigma):
		visible = false
		return
	visible = true
	var floor_y := float(st.get("fog_floor_y", 0.0))
	var top_y := float(st.get("fog_top_y", floor_y + 30.0))
	var depth := maxf(top_y - floor_y, 5.0)
	var feather := clampf(depth * 0.35, 4.0, 40.0)
	# A valley fog fills EVERYTHING below its top, not just the hollow the floor
	# was measured in — the camera (or a deeper gully) may sit far below the
	# site's floor. The box reaches down past both; the froxel cost does not
	# depend on the box's size.
	var y0 := minf(floor_y, cam_pos.y) - BELOW_FLOOR_M
	var y1 := top_y + feather
	_vol.size = Vector3(HALF_XZ_M * 2.0, y1 - y0, HALF_XZ_M * 2.0)
	_vol.global_position = Vector3(cam_pos.x, (y0 + y1) * 0.5, cam_pos.z)
	# Fog drifts with the air but slowly — at a third of the wind, capped, so a
	# breezy hour does not stream it past like smoke.
	var w := wind_xz.limit_length(2.0) * 0.35
	_drift -= Vector3(w.x, 0.0, w.y) * delta
	var col: Color = st.get("fog_color", Color(0.85, 0.87, 0.9))
	# A night fog is not a glowing white box: the albedo scatters whatever light
	# reaches it, and main.gd fades the ambient injection at night, so keeping
	# the albedo honest is enough. A slight cool shift reads as moonlit.
	col = col.lerp(Color(col.r * 0.85, col.g * 0.9, col.b), clampf(night_amount, 0.0, 1.0))
	_mat.set_shader_parameter("density_sigma", sigma)
	_mat.set_shader_parameter("top_y", top_y)
	_mat.set_shader_parameter("feather_m", feather)
	_mat.set_shader_parameter("albedo", Vector3(col.r, col.g, col.b))
	_mat.set_shader_parameter("drift", _drift)
	# Skylight in the droplets, independent of the player's ambient-light pref
	# (which can be 0). Scaled so a noon fog reads bright grey, not white-out.
	# Fog is lit by the white sky dome. As the sun warms toward the horizon its
	# beam is faded out of the fog (main.gd), so the emission makes up the light
	# and the albedo is pulled toward neutral white — a slight blue-grey, never
	# yellow.
	# The sun's colour stays horizon-orange all night (DaylightModel holds the
	# horizon colour below 0°), so warmth only counts while it is not night —
	# otherwise it overrides the moonlit cool shift above.
	var warm := sun_warmth * (1.0 - clampf(night_amount, 0.0, 1.0))
	var sl := clampf(sky_light, 0.0, 1.0) * SKY_EMISSION_GAIN * (1.0 + 0.5 * warm)
	var neutral := col.lerp(Color(0.86, 0.88, 0.91), clampf(warm * 1.5, 0.0, 1.0))
	_mat.set_shader_parameter("albedo", Vector3(neutral.r, neutral.g, neutral.b))
	_mat.set_shader_parameter("sky_emission", Vector3(neutral.r * sl, neutral.g * sl, neutral.b * sl))


## How far the camera sits above the fog top (negative = inside it). main.gd
## sizes the froxel range from this so the layer is still sampled from the air.
static func camera_above_top(st: Dictionary, cam_y: float) -> float:
	return cam_y - float(st.get("fog_top_y", 0.0))

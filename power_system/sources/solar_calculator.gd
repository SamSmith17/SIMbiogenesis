class_name SolarPanelSource
extends EnergySource

## Solar power calculator that estimates power output based on sun position
## and panel orientation. Models an 18 x 220W array (3.96 kW) with PowMR
## LVM5K inverter (5.0 kW max solar input).
##
## The `power_updated` signal, accessors, Main-node discovery, and hourly
## energy tracking now live in EnergySource; this class only supplies the
## photovoltaic power model.

const PANEL_COUNT : int = 18
const PANEL_WATTAGE : float = 220.0  # Watts per panel
const PEAK_CAPACITY_KW : float = PANEL_COUNT * PANEL_WATTAGE / 1000.0  # 3.96 kW

# Inverter clipping - PowMR LVM5K has 5 kW max solar input
const INVERTER_MAX_SOLAR_KW : float = 5.0

# Panel orientation (normal vector pointing up from panel surface)
# Horizontal by default; matches solar_ui.gd user setting
var panel_tilt_degrees : float = 0.0
var panel_azimuth_degrees : float = 180.0  # Due south

# Efficiency factors
const SYSTEM_EFFICIENCY : float = 0.80  # PowMR inverter losses, wiring, etc.
const TEMPERATURE_DERATING : float = 0.90  # Average temp derating (desert climate)
const SOILING_FACTOR : float = 0.93  # Desert dust at Bombay Beach

# Real-world calibration factor from spring equinox field data
const SYSTEM_CALIBRATION : float = 0.53


func _init() -> void:
	source_name = "Solar Array"
	# SolarUI models the solar array internally; contributing this estimator
	# to the grid balance as well would double-count solar generation.
	contribute_to_grid = false


func _compute_power_kw() -> float:
	if main_node == null or not "sun" in main_node:
		return 0.0

	var sun = main_node.sun as DirectionalLight3D
	if sun == null:
		return 0.0

	# Get sun direction (pointing FROM sun TO scene)
	# DirectionalLight3D's -Z axis points toward the light target
	var sun_direction: Vector3 = -sun.global_transform.basis.z.normalized()

	# Sun must be above horizon to generate power
	if sun_direction.y <= 0.0:
		return 0.0

	# Calculate panel normal vector based on tilt and azimuth
	var panel_normal := _get_panel_normal()

	# Calculate angle between sun and panel normal
	var cos_incidence: float = sun_direction.dot(panel_normal)

	# If sun is behind panel, no power
	if cos_incidence <= 0.0:
		return 0.0

	# Direct irradiance factor (simplified - assumes clear sky)
	# At solar noon with sun directly facing panel, this would be 1.0
	var direct_factor: float = cos_incidence

	# Add diffuse component (sky contributes even when not direct)
	# Roughly 10-15% of power comes from diffuse light
	var diffuse_factor: float = 0.12 * sun_direction.y  # More diffuse when sun is higher

	# Air mass factor - more atmosphere to penetrate at low angles
	var air_mass := 1.0 / maxf(sun_direction.y, 0.05)
	var atmospheric_loss := pow(0.7, pow(air_mass, 0.678))

	# Combine factors
	var irradiance_factor: float = (direct_factor + diffuse_factor) * atmospheric_loss
	irradiance_factor = clampf(irradiance_factor, 0.0, 1.0)

	# Apply efficiency factors
	var total_efficiency := SYSTEM_EFFICIENCY * TEMPERATURE_DERATING * SOILING_FACTOR

	# Calculate instantaneous power
	var power_kw := PEAK_CAPACITY_KW * irradiance_factor * total_efficiency * SYSTEM_CALIBRATION

	# Apply inverter clipping (PowMR LVM5K max solar input)
	return minf(maxf(power_kw, 0.0), INVERTER_MAX_SOLAR_KW)


func _get_panel_normal() -> Vector3:
	# Convert panel orientation to a normal vector
	# Panels face upward and tilted toward the azimuth direction
	var tilt_rad := deg_to_rad(panel_tilt_degrees)
	var azimuth_rad := deg_to_rad(panel_azimuth_degrees)

	# Start with vertical (flat panel facing up)
	# Then tilt toward the azimuth direction
	var normal := Vector3(
		sin(tilt_rad) * sin(azimuth_rad),
		cos(tilt_rad),
		-sin(tilt_rad) * cos(azimuth_rad)
	)

	return normal.normalized()


func get_peak_capacity_kw() -> float:
	return PEAK_CAPACITY_KW

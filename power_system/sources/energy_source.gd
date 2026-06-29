class_name EnergySource
extends Node

## Base class for electrical generation sources (solar, wind, hydro, …).
##
## Defines the source contract established by solar_calculator.gd: a
## `power_updated(instant_kw, daily_kwh)` signal plus the
## get_current_power_kw / get_daily_energy_kwh / get_peak_capacity_kw
## accessors, Main-node discovery for world time, and hourly energy
## bookkeeping. Subclasses implement `_compute_power_kw()` only.
##
## Members of the "energy_sources" group with `contribute_to_grid` set are
## summed by SolarUI into the battery/net energy balance each sim step.

signal power_updated(instant_kw: float, daily_kwh: float)

## Display name used by monitoring UIs.
@export var source_name: String = "Energy Source"

## When true, SolarUI adds this source's output to the system energy
## balance. SolarPanelSource defaults this OFF because SolarUI already
## models the solar array internally — leaving it on would double-count.
@export var contribute_to_grid: bool = true

var current_power_kw: float = 0.0
var daily_energy_kwh: float = 0.0
var last_hour: int = -1
var hourly_power_samples: Array[float] = []

const _CALC_INTERVAL: float = 0.5  # 2 Hz, matches solar_calculator.gd
var _calc_timer: float = 0.0

## Main scene node (world clock: day_time, month, time_scale, lat).
var main_node: Node = null


func _ready() -> void:
	add_to_group("energy_sources")
	add_to_group("graph_linkable")
	await get_tree().process_frame
	_find_main_node()


func _find_main_node() -> void:
	var root := get_tree().root
	for child in root.get_children():
		if "day_time" in child and "sun" in child:
			main_node = child
			break
	if main_node == null:
		var current_scene := get_tree().current_scene
		if current_scene and "day_time" in current_scene:
			main_node = current_scene


func _process(delta: float) -> void:
	if main_node == null:
		_find_main_node()
		return
	_calc_timer += delta
	if _calc_timer < _CALC_INTERVAL:
		return
	_calc_timer -= _CALC_INTERVAL
	current_power_kw = maxf(_compute_power_kw(), 0.0)
	_track_energy()


## Subclasses return instantaneous output in kW for the current world state.
func _compute_power_kw() -> float:
	return 0.0


## Subclasses return nameplate capacity in kW.
func get_peak_capacity_kw() -> float:
	return 0.0


func get_current_power_kw() -> float:
	return current_power_kw


func get_daily_energy_kwh() -> float:
	return daily_energy_kwh


## World-clock helpers -------------------------------------------------------

func _world_hour() -> float:
	if main_node == null:
		return 12.0
	var dt: Variant = main_node.get("day_time")
	return float(dt) if dt != null else 12.0


func _world_month() -> int:
	if main_node == null:
		return 6
	var m: Variant = main_node.get("month")
	return clampi(int(m) if m != null else 6, 1, 12)


func _world_day() -> int:
	if main_node == null:
		return 15
	var d: Variant = main_node.get("day")
	return clampi(int(d) if d != null else 15, 1, 31)


## The WeatherService autoload when it has a dataset covering the sim
## location; null otherwise (callers keep their synthetic fallbacks).
func _covering_weather_service() -> Node:
	var ws := get_node_or_null("/root/WeatherService")
	if ws == null or main_node == null or not ws.has_method("covers"):
		return null
	var lat: Variant = main_node.get("latitude")
	var lon: Variant = main_node.get("longitude")
	if lat == null or lon == null:
		return null
	if not bool(ws.call("covers", float(lat), float(lon))):
		return null
	return ws


## Hourly bucket bookkeeping, lifted from solar_calculator.gd so every
## source reports daily energy the same way the solar array does.
func _track_energy() -> void:
	if main_node == null:
		return
	var current_hour := int(_world_hour())

	# Reset daily energy at midnight
	if current_hour == 0 and last_hour == 23:
		daily_energy_kwh = 0.0
		hourly_power_samples.clear()

	hourly_power_samples.append(current_power_kw)

	# When the hour rolls over, bank the average power as that hour's kWh.
	if current_hour != last_hour and last_hour >= 0:
		if hourly_power_samples.size() > 0:
			var avg_power := 0.0
			for sample in hourly_power_samples:
				avg_power += sample
			avg_power /= hourly_power_samples.size()
			daily_energy_kwh += avg_power  # 1 hour worth of energy
			hourly_power_samples.clear()

	last_hour = current_hour
	power_updated.emit(current_power_kw, daily_energy_kwh)

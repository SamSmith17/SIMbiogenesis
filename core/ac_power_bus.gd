extends Node
## Global AC power state bus — single source of truth for inverter output /
## low-SOC shutdown. SolarUI publishes; all consumers subscribe here instead
## of walking the scene tree (resilient to load order and embed mirrors).

signal power_availability_changed(available: bool)
signal ac_shutdown_changed(active: bool, reason: String)

var power_available: bool = true
var ac_output_enabled: bool = true
var shutdown_active: bool = false
var shutdown_reason: String = ""

var _authority: Node = null


func register_authority(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
		return
	_authority = node
	# Pull current state immediately so late subscribers see the right values.
	if node.has_method("is_power_available"):
		power_available = bool(node.call("is_power_available"))
	if node.has_method("is_ac_output_enabled"):
		ac_output_enabled = bool(node.call("is_ac_output_enabled"))
	if node.has_method("is_soc_protect_active"):
		shutdown_active = bool(node.call("is_soc_protect_active"))
	elif not ac_output_enabled:
		shutdown_active = true


func publish(
		available: bool,
		ac_enabled: bool,
		reason: String = "",
		shutdown: bool = false,
		force: bool = false) -> void:
	var avail_changed := available != power_available
	var shut_changed := shutdown != shutdown_active or reason != shutdown_reason
	var ac_changed := ac_enabled != ac_output_enabled
	if not force and not avail_changed and not shut_changed and not ac_changed:
		return
	power_available = available
	ac_output_enabled = ac_enabled
	shutdown_active = shutdown
	shutdown_reason = reason
	if avail_changed or force:
		power_availability_changed.emit(available)
	if shut_changed or (force and shutdown):
		ac_shutdown_changed.emit(shutdown, reason)
	elif force and not shutdown and shutdown_reason.is_empty():
		ac_shutdown_changed.emit(false, "")


## Connect `callback(available: bool)` to power changes; returns true when hooked.
func hook_availability(node: Node, callback: Callable) -> bool:
	if node == null or not callback.is_valid():
		return false
	if not power_availability_changed.is_connected(callback):
		power_availability_changed.connect(callback)
	callback.call(power_available)
	return true


## Deferred retry until the bus has been seeded (handles consumer _ready before SolarUI).
func hook_availability_deferred(node: Node, callback: Callable, attempt: int = 0) -> void:
	if node == null or not is_instance_valid(node):
		return
	if hook_availability(node, callback):
		return
	if attempt >= 40:
		push_warning("AcPowerBus: could not hook consumer %s" % str(node.get_path()))
		return
	var wait := 0.15 if attempt < 8 else 0.35
	get_tree().create_timer(wait).timeout.connect(
		func() -> void: hook_availability_deferred(node, callback, attempt + 1),
		CONNECT_ONE_SHOT)

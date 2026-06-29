class_name GraphSimLoad
extends Node
## Runtime proxy for a graph-only load (library-spawned appliance / acload /
## processor items that are NOT linked to a real scene PowerDevice).
##
## Joins the "power_consumers" group so its wattage contributes to
## solar_ui.current_load_kw. Exposes turn_on/turn_off/toggle so
## SceneNodeAction can target it via `device_path`.
##
## When state changes, the underlying graph item's specs.current_state is
## updated so the graph canvas flow animation reflects it.

signal state_changed(is_on: bool)

## Graph item id this sim-load represents.
var item_id: String = ""
## Rated max draw (W) — shown in node specs but currently the simulation
## uses `avg_power_watts` for contribution.
var rated_power_watts: float = 200.0
## Average power draw (W) — what the simulation actually counts.
var avg_power_watts: float = 200.0
## Whether the load is actively drawing power right now.
var is_on: bool = false
## User/requested switch state. Effective draw only occurs when AC is available.
var _requested_on: bool = false
var _ac_power_available: bool = true
var _solar_ui: Node = null
var _connect_attempts: int = 0
## Reference to the GraphModel that owns `item_id`. Weakly held via Variant
## so we don't prevent cleanup.
var model_ref: Variant = null


func _ready() -> void:
	if not is_in_group("power_consumers"):
		add_to_group("power_consumers")
	# Mark so solar_bridge skips us (prevents duplicate virtual graph items).
	set_meta("graph_sim_load", true)
	_requested_on = is_on
	call_deferred("_connect_to_power_system")


# ---------------------------------------------------------------------------
# SceneNodeAction / device-like API
# ---------------------------------------------------------------------------

func turn_on() -> void:
	if _requested_on:
		return
	_requested_on = true
	_recompute_effective_state(true)


func turn_off() -> void:
	if not _requested_on:
		return
	_requested_on = false
	_recompute_effective_state(true)


func toggle() -> void:
	if _requested_on:
		turn_off()
	else:
		turn_on()


# ---------------------------------------------------------------------------
# Solar-UI load contribution
# ---------------------------------------------------------------------------

func get_current_power() -> float:
	return avg_power_watts if is_on else 0.0


func get_state_string() -> String:
	return "on" if is_on else "off"


# ---------------------------------------------------------------------------
# Host integration
# ---------------------------------------------------------------------------

## Mirror model → node without re-emitting state_changed (used by the host
## when live specs are refreshed or when the graph is loaded from disk).
func sync_from_model(target_is_on: bool, rated_w: float, avg_w: float) -> void:
	rated_power_watts = rated_w
	avg_power_watts = avg_w
	_requested_on = target_is_on
	_recompute_effective_state(false)


func _connect_to_power_system() -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("hook_availability_deferred"):
		apb.call("hook_availability_deferred", self, Callable(self, "_on_power_availability_changed"))
		return
	var tree := get_tree()
	if tree == null:
		return
	var solar_ui := _find_solar_ui(tree.root)
	if solar_ui == null:
		if _connect_attempts < 40:
			_connect_attempts += 1
			get_tree().create_timer(0.25).timeout.connect(_connect_to_power_system, CONNECT_ONE_SHOT)
		return
	_connect_attempts = 0
	_solar_ui = solar_ui
	if solar_ui.has_signal("power_availability_changed"):
		if not solar_ui.power_availability_changed.is_connected(_on_power_availability_changed):
			solar_ui.power_availability_changed.connect(_on_power_availability_changed)
	if solar_ui.has_method("is_power_available"):
		_ac_power_available = bool(solar_ui.call("is_power_available"))
	_recompute_effective_state(false)


func _find_solar_ui(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_power_available"):
		if node.has_method("is_primary_power_source") and not node.call("is_primary_power_source"):
			pass
		else:
			return node
	for child in node.get_children():
		var result := _find_solar_ui(child)
		if result != null:
			return result
	return null


func _on_power_availability_changed(available: bool) -> void:
	_ac_power_available = available
	_recompute_effective_state(true)


func _recompute_effective_state(emit_signal: bool) -> void:
	var effective_on := _requested_on and _ac_power_available
	var changed := is_on != effective_on
	is_on = effective_on
	_apply_state_to_model()
	if changed and emit_signal:
		state_changed.emit(is_on)


func _apply_state_to_model() -> void:
	if model_ref == null:
		return
	if not (model_ref.has_method("get_item") and model_ref.has_method("update_item")):
		return
	var it: Dictionary = model_ref.call("get_item", item_id) as Dictionary
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	specs["current_state"] = "on" if is_on else "off"
	specs["requested_state"] = "on" if _requested_on else "off"
	model_ref.call("update_item", item_id, {"specs": specs})

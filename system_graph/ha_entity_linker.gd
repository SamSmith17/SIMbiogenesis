class_name HAEntityLinker
extends Node

## Routes live Home Assistant sensor values into graph items via per-role links
## stored in each item's specs.ha_links, and pushes well-known roles into solar_ui
## overrides so the simulation reflects the real system in live mode and uses the
## latest live snapshot as the base when time_scale is increased.
##
## Roles (conventions):
##   panel:       power  (W), voltage (V), current (A)
##   battery:     soc    (%), voltage (V), power   (W), current (A)
##   smartbattery: same roles as battery
##   controller:  ac_power (W), voltage (V), current (A)
##
## Each item may define at most one entity_id per role. Values are stored at
##   item.specs.ha_links[role]   -> entity_id
##   item.specs.ha_live[role]    -> {value: float, unit: String, t: int}

signal ha_live_updated(item_id: String, role: String, value: float)

const SOLAR_UI_PATHS := ["Main/UILayer/SolarUI", "UILayer/SolarUI"]
## Anything above ~1.5× real-time is treated as "simulate forward" mode so the sim
## can advance from the last live snapshot without HA snapping every reading.
const REALTIME_SCALE_REF := 1.0 / 3600.0
const REALTIME_THRESHOLD := REALTIME_SCALE_REF * 1.5

var model: GraphModel = null
var _ha_client: Node = null
var _solar_ui: Node = null
var _main_node: Node = null
var _was_simulating: bool = false

## entity_id → Array of {item_id, role, unit, scale}
var _routes: Dictionary = {}


func setup(mdl: GraphModel) -> void:
	model = mdl
	_resolve_nodes()
	if _ha_client != null and _ha_client.has_signal("sensor_updated") and not _ha_client.sensor_updated.is_connected(_on_sensor_updated):
		_ha_client.sensor_updated.connect(_on_sensor_updated)
	if _ha_client != null and _ha_client.has_signal("authentication_status_changed") and not _ha_client.authentication_status_changed.is_connected(_on_auth_changed):
		_ha_client.authentication_status_changed.connect(_on_auth_changed)


func teardown() -> void:
	if _ha_client != null and _ha_client.has_signal("sensor_updated") and _ha_client.sensor_updated.is_connected(_on_sensor_updated):
		_ha_client.sensor_updated.disconnect(_on_sensor_updated)
	if _ha_client != null and _ha_client.has_signal("authentication_status_changed") and _ha_client.authentication_status_changed.is_connected(_on_auth_changed):
		_ha_client.authentication_status_changed.disconnect(_on_auth_changed)
	_routes.clear()


## Rebuild routing table from current model, subscribe in HAClient, request initial states.
## Call this after inspector saves new links.
func refresh_subscriptions() -> void:
	_resolve_nodes()
	_rebuild_routes()
	# Even without HA connected we keep routes so incoming sensor events from a
	# future reconnect will be routed correctly via _on_auth_changed.
	if _ha_client == null:
		return
	var ids: Array[String] = []
	for k in _routes.keys():
		var s: String = str(k)
		if not s.is_empty() and not ids.has(s):
			ids.append(s)
	# Merge with existing subs so manual subscriptions from ha_connection_ui aren't lost
	var existing_v: Variant = _ha_client.get("subscribed_entities")
	if existing_v is Array:
		for e in (existing_v as Array):
			var se: String = str(e)
			if not se.is_empty() and not ids.has(se):
				ids.append(se)
	if ids.is_empty():
		return
	if _ha_client.has_method("subscribe_to_entities"):
		_ha_client.subscribe_to_entities(ids)
	if _ha_client.has_method("get_entity_states"):
		_ha_client.get_entity_states(ids)


## Apply a historical (replayed) value to every graph item linked to the
## given entity.  Used by HistoryPlayer to drive the canvas while scrubbing
## through recorded HA data.  Bypasses the SimMode "should_apply_live_data"
## gate because, in HISTORICAL mode, this player is the legitimate writer.
##
## Behaviour mirrors _on_sensor_updated (ha_live cache + display fields)
## but tags the source so consumers can tell live from historical pushes.
func apply_historical_value(entity_id: String, value: float, unit: String,
		t_unix: int) -> void:
	if model == null:
		return
	var routes: Array = _routes.get(entity_id, []) as Array
	if routes.is_empty():
		return
	for r: Dictionary in routes:
		var iid: String = r.get("item_id", "") as String
		var role: String = r.get("role", "") as String
		var it: Dictionary = model.get_item(iid)
		if it.is_empty():
			continue
		var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		var live: Dictionary = (specs.get("ha_live", {}) as Dictionary).duplicate(true)
		live[role] = {"value": value, "unit": unit, "t": t_unix, "source": "history"}
		specs["ha_live"] = live
		var itype: String = it.get("type", "") as String
		_mirror_to_spec(specs, itype, role, value, unit)
		model.update_item(iid, {"specs": specs})
		ha_live_updated.emit(iid, role, value)


## Returns true if HAClient is connected & authenticated.
func is_live() -> bool:
	_resolve_nodes()
	if _ha_client == null:
		return false
	return bool(_ha_client.get("is_connected")) and bool(_ha_client.get("is_authenticated"))


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _resolve_nodes() -> void:
	var tr := get_tree()
	if tr == null:
		return
	if not is_instance_valid(_ha_client):
		# HAClient lives as a child of the main scene node, not directly under
		# /root.  Mirror InverterBridge's search: iterate every root child and
		# find the one that has "HAClient" as a child node.
		_ha_client = tr.root.get_node_or_null("HAClient")
		if not is_instance_valid(_ha_client):
			for scene_child in tr.root.get_children():
				var candidate := scene_child.get_node_or_null("HAClient")
				if candidate != null:
					_ha_client = candidate
					break
		# Reconnect signal whenever we first resolve the client.
		if is_instance_valid(_ha_client):
			if _ha_client.has_signal("sensor_updated") and not _ha_client.sensor_updated.is_connected(_on_sensor_updated):
				_ha_client.sensor_updated.connect(_on_sensor_updated)
			if _ha_client.has_signal("authentication_status_changed") and not _ha_client.authentication_status_changed.is_connected(_on_auth_changed):
				_ha_client.authentication_status_changed.connect(_on_auth_changed)
	if not is_instance_valid(_solar_ui):
		for p in SOLAR_UI_PATHS:
			var n := tr.root.get_node_or_null(p)
			if n != null:
				_solar_ui = n
				break
	if not is_instance_valid(_main_node):
		var sc := tr.current_scene
		if sc != null and sc.name == "Main":
			_main_node = sc
		elif sc != null and sc.has_node("/root/Main"):
			_main_node = tr.root.get_node_or_null("Main")
		else:
			_main_node = tr.root.get_node_or_null("Main")


func _is_simulating_forward() -> bool:
	# TimeDirector is the single mode authority — SIMULATE means "not mirroring
	# live", which is exactly when HA overrides should be snapshotted then frozen.
	var td := get_node_or_null("/root/TimeDirector")
	if td != null and td.has_method("is_sim"):
		return bool(td.call("is_sim"))
	# Fallbacks when TimeDirector is unavailable (e.g. isolated tests).
	if _solar_ui != null and _solar_ui.has_method("is_simulating_from_live"):
		if bool(_solar_ui.is_simulating_from_live()):
			return true
	if _main_node != null and _main_node.get("time_scale") != null:
		return float(_main_node.time_scale) > REALTIME_THRESHOLD
	return false


func _process(_delta: float) -> void:
	_resolve_nodes()
	# On transition live → simulating-forward, snapshot current HA overrides so
	# solar_ui can use them as the starting point and then run forward.
	var simulating := _is_simulating_forward()
	if simulating and not _was_simulating:
		_snapshot_for_sim()
	elif not simulating and _was_simulating:
		# Back to live: let the next HA update repopulate overrides naturally.
		pass
	_was_simulating = simulating


func _snapshot_for_sim() -> void:
	if _solar_ui == null:
		return
	# If solar_ui is mid-way through live readings, emit the simulation_started
	# signal through TimeUI so solar_ui snapshots & clears overrides itself.
	var time_ui: Node = null
	var sc := get_tree().current_scene if get_tree() != null else null
	if sc != null:
		time_ui = sc.get_node_or_null("UILayer/TimeUI")
	if time_ui == null and _solar_ui.get_parent() != null:
		time_ui = _solar_ui.get_parent().get_node_or_null("TimeUI")
	if time_ui != null and time_ui.has_method("_notify_simulation_start"):
		time_ui.call("_notify_simulation_start")
		return
	if is_instance_valid(SimSettingsController):
		SimSettingsController.notify_simulation_start()
		return
	# Fallback: directly snapshot overrides on solar_ui
	var soc: Variant = _solar_ui.get("_ha_battery_soc_override")
	var ld:  Variant = _solar_ui.get("_ha_load_override")
	var sl:  Variant = _solar_ui.get("_ha_solar_override")
	if soc != null and float(soc) >= 0.0:
		_solar_ui.set("_sim_start_battery_soc", float(soc))
	if ld != null and float(ld) >= 0.0:
		_solar_ui.set("_sim_start_load_kw", float(ld))
	if sl != null and float(sl) >= 0.0:
		_solar_ui.set("_sim_start_solar_kw", float(sl))
	_solar_ui.set("_simulation_mode", true)
	_solar_ui.set("_ha_battery_soc_override", -1.0)
	_solar_ui.set("_ha_load_override", -1.0)
	_solar_ui.set("_ha_solar_override", -1.0)


func _rebuild_routes() -> void:
	_routes.clear()
	if model == null:
		return
	for it: Dictionary in model.items:
		var iid: String = it.get("id", "") as String
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var links: Dictionary = specs.get("ha_links", {}) as Dictionary
		for role: String in links.keys():
			var eid: String = str(links[role]).strip_edges()
			if eid.is_empty():
				continue
			var arr: Array = _routes.get(eid, []) as Array
			arr.append({"item_id": iid, "role": role})
			_routes[eid] = arr


func _on_auth_changed(authenticated: bool) -> void:
	if authenticated:
		# Re-apply subscriptions so reconnects continue to stream our entities.
		call_deferred("refresh_subscriptions")


func _on_sensor_updated(entity_id: String, state: Dictionary) -> void:
	if model == null or _routes.is_empty():
		return
	var routes: Array = _routes.get(entity_id, []) as Array
	if routes.is_empty():
		return
	var sv: String = str(state.get("state", ""))
	if sv in ["unavailable", "unknown", ""]:
		return
	# Normalize boolean HA states ("on"/"off") to 1.0 / 0.0 so that switch
	# entities can be handled numerically the same as sensor entities.
	var numeric: float
	var sv_lower := sv.to_lower()
	if sv_lower == "on":
		numeric = 1.0
	elif sv_lower == "off":
		numeric = 0.0
	else:
		numeric = sv.to_float()
	var unit: String = str(state.get("attributes", {}).get("unit_of_measurement", ""))
	var t_unix: int = int(Time.get_unix_time_from_system())
	# In SIMULATE mode we still want to keep the ha_live cache fresh (so the
	# next sim run can pick up real "initial conditions") but we must NOT
	# mirror the value into display fields or push it to solar_ui — that
	# would let live data leak into a forward simulation.
	var sm: Node = get_node_or_null("/root/SimMode")
	var apply_live: bool = sm == null or bool(sm.call("should_apply_live_data"))
	for r: Dictionary in routes:
		var iid: String = r.get("item_id", "") as String
		var role: String = r.get("role", "") as String
		var it: Dictionary = model.get_item(iid)
		if it.is_empty():
			continue
		var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		var live: Dictionary = (specs.get("ha_live", {}) as Dictionary).duplicate(true)
		live[role] = {"value": numeric, "unit": unit, "t": t_unix}
		specs["ha_live"] = live
		var itype: String = it.get("type", "") as String
		if apply_live:
			# Mirror into display-friendly fields so the canvas reflects HA.
			_mirror_to_spec(specs, itype, role, numeric, unit)
		# A measured value arriving is not a player edit: it must not move
		# GraphModel.user_rev (which would invalidate a rendered range every
		# few seconds while HA is connected).
		var was_sim_writing := model.sim_writing
		model.sim_writing = true
		model.update_item(iid, {"specs": specs})
		model.sim_writing = was_sim_writing
		if apply_live:
			_push_to_solar_ui(itype, role, numeric, unit)
		ha_live_updated.emit(iid, role, numeric)


## Copy the live HA value into well-known spec fields so the canvas/battery/panel
## widgets show the live reading without waiting for the full simulation cycle.
func _mirror_to_spec(specs: Dictionary, itype: String, role: String, value: float, unit: String) -> void:
	match itype:
		"appliance", "acload":
			match role:
				"power":
					# Write live watts into avg_watts — the field the canvas
					# and simulation both read for appliance current draw.
					var w: float = value
					if unit.to_lower() == "kw":
						w = value * 1000.0
					specs["avg_watts"] = w
				"switch":
					# Normalize 1.0/0.0 (already done by linker) to on/off string
					specs["current_state"] = "on" if value >= 0.5 else "off"
				"energy":
					specs["energy_kwh"] = value
				"voltage":
					specs["voltage_v"] = value
				"current":
					specs["current_a"] = value
		"panel":
			if role == "power":
				# W → kW, stored in current_output_kw (same key used by solar_bridge)
				var w: float = value
				if unit.to_lower() == "kw":
					w = value * 1000.0
				specs["current_output_kw"] = w / 1000.0
		"battery", "smartbattery":
			if role == "soc":
				specs["soc"] = clampf(value * 0.01 if value > 1.5 else value, 0.0, 1.0)
			elif role == "voltage":
				specs["voltage"] = value
		"controller":
			if role == "ac_power":
				var w: float = value
				if unit.to_lower() == "kw":
					w = value * 1000.0
				specs["current_output_kw"] = w / 1000.0
		"shelly4pm":
			# role format: "cN_power" | "cN_switch" | "cN_energy"  (N = 0..3)
			if role.length() >= 2:
				var ci_str := role.substr(1, 1)   # "c0_power" → "0"
				if role.ends_with("_power"):
					specs["c%s_power_w" % ci_str] = value
				elif role.ends_with("_switch"):
					# value is 1.0 (on) or 0.0 (off) after normalization above
					specs["c%s_on" % ci_str] = value >= 0.5
				elif role.ends_with("_energy"):
					specs["c%s_energy_kwh" % ci_str] = value


## Push well-known roles into solar_ui overrides so the simulation core reflects HA.
func _push_to_solar_ui(itype: String, role: String, value: float, unit: String) -> void:
	if _solar_ui == null:
		return
	# Don't fight the simulator while it's running forward from a snapshot.
	if _is_simulating_forward():
		return
	var to_kw: float = value / 1000.0
	if unit.to_lower() == "kw":
		to_kw = value
	match itype:
		"battery", "smartbattery":
			if role == "soc":
				var soc_pct: float = clampf(value if value > 1.5 else value * 100.0, 0.0, 100.0)
				_solar_ui.set("_ha_battery_soc_override", soc_pct)
				var cap_kwh: float = 16.0
				if _solar_ui.has_method("get_battery_capacity_kwh"):
					cap_kwh = float(_solar_ui.get_battery_capacity_kwh())
				elif _solar_ui.get("BATTERY_CAPACITY_KWH") != null:
					cap_kwh = float(_solar_ui.get("BATTERY_CAPACITY_KWH"))
				_solar_ui.set("battery_kwh_stored", (soc_pct / 100.0) * cap_kwh)
		"panel":
			if role == "power":
				_solar_ui.set("_ha_solar_override", to_kw)
		"controller":
			if role == "ac_power":
				_solar_ui.set("_ha_load_override", to_kw)

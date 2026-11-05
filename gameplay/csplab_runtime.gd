class_name CspLabRuntime
extends Node

## A placed concentrator from the solar concentrator designer, alive in the
## world. Twice a second it reads the sun from the world clock (Meeus SPA,
## the same sun the graph's tick uses) and:
##  - turns the builder to face it the way its mount would (two-axis
##    pedestals, one-axis troughs, every mirror row or heliostat of a field;
##    CspLabBuilder.set_sun). Below the horizon it stows.
##  - lights the receiver with the flux on it now: the direct beam at this
##    instant (real weather where there is some) through the design's
##    optical efficiency at this sun, over the design's own flux
##    (CspLabBuilder.set_glow_focus) — dark at night, under cloud, or when a
##    fixed optic has lost the sun.
##  - publishes its tracking drives as degrees (CspLabActuators.channels,
##    off the pose it just drew) and, when the record's `csplab_ha` says so,
##    sends each to its Home Assistant entity so a real motor can follow.
## Attached by PlacedPropRuntime to any prop whose model_id is
## CspLabBuilder.MODEL_ID; the heat itself is the graph node's
## (SystemGraphView._tick_graph_csplab).
##
## Cost: everything runs at the 0.5 s poll except `advance_live`, which
## finishes an efficiency trace in small chunks inside one budget a frame
## shared by every concentrator (CspLabSite.LIVE_TRACE_BUDGET_US). The
## drive angles are re-derived only when the pose moved; Home Assistant is
## looked at once a second and sends at most MAX_HA_SENDS calls a pass,
## biggest change first. Profiled as csp_runtime (csp_pose, csp_drives,
## csp_glow, csp_ha) on the F3 HUD; tools/bench/csplab_bench.gd measures it.

const _POLL_S := 0.5
## Skip a sun move smaller than this (rad, ≈ 0.09°): a real tracker steps.
const _MIN_MOVE := 0.0015
## Home Assistant is serviced at most this often (s), and sends at most this
## many calls a pass (a 150-heliostat field has 300 drives).
const _HA_POLL_S := 1.0
const MAX_HA_SENDS := 16

var _builder: CspLabBuilder = null
var _poll := 999.0
var last_sun := Vector3.ZERO
## The drives now: [{id, label, deg, min, max, tip}].
var channels: Array = []
## The flux on the receiver now over the design's (0 = dark).
var focus := 0.0
var dni_now := 0.0
## Home Assistant: what was last sent per entity, and a line for the UI.
var ha_status := ""
var ha_sent: Dictionary = {}
var ha_sends := 0
var _ha_since := 999.0
var _ha_errors := 0
var _ha_poll := 999.0
var _pose_seen := -1


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != CspLabBuilder.MODEL_ID or prop.get_node_or_null("CspLabRuntime") != null:
		return
	var rt := CspLabRuntime.new()
	rt.name = "CspLabRuntime"
	prop.add_child(rt)


## The runtime on a placed prop node (null when it has none).
static func of(prop: Node) -> CspLabRuntime:
	if prop == null:
		return null
	return prop.get_node_or_null("CspLabRuntime") as CspLabRuntime


func builder() -> CspLabBuilder:
	return _builder


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var p := get_parent()
	if p == null:
		return
	_builder = null
	for n in p.find_children("*", "Node3D", true, false):
		if n is CspLabBuilder:
			_builder = n as CspLabBuilder
			break
	last_sun = Vector3.ZERO


func _process(delta: float) -> void:
	_ha_since += delta
	_ha_poll += delta
	if _builder == null or not is_instance_valid(_builder) or not _builder.is_inside_tree():
		# A rebuild (Apply from the designer) replaced the model under us.
		_bind()
		if _builder == null:
			return
		_pose_seen = -1
	# An efficiency trace started at a poll is finished a chunk a frame.
	CspLabSite.advance_live(_builder.design)
	_poll += delta
	if _poll < _POLL_S:
		return
	_poll = 0.0
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return
	PerfSpan.begin("csp_runtime")
	_poll_once(main)
	PerfSpan.end("csp_runtime")


func _poll_once(main: Node) -> void:
	var clock_obj: Variant = main.get("clock")
	if clock_obj == null or not (clock_obj as Object).has_method("get_julian_day_utc"):
		return
	var la: Variant = main.get("latitude")
	var lo: Variant = main.get("longitude")
	var lat := float(la) if la != null else 35.0
	var lon := float(lo) if lo != null else -115.0
	var sp := SolarPosition.get_position(lat, lon, float((clock_obj as Object).call("get_julian_day_utc")))
	var el := float(sp.get("elevation_deg", -10.0))
	var s := CspLabSite.sun_world(float(sp.get("azimuth_deg", 180.0)), el)
	# Every placed mirror shares one material: its sun, change-gated.
	CspLabBuilder.push_world_sun(s)
	# The prop may be turned: the builder's frame is the prop's.
	var gb := _builder.global_transform.basis.orthonormalized()
	var s_local := gb.transposed() * s
	if s_local.distance_to(last_sun) >= _MIN_MOVE:
		last_sun = s_local
		_builder.lat = lat
		PerfSpan.begin("csp_pose")
		_builder.set_sun(s_local)
		PerfSpan.end("csp_pose")
	if _builder.pose_serial != _pose_seen:
		_pose_seen = _builder.pose_serial
		PerfSpan.begin("csp_drives")
		channels = CspLabActuators.channels(_builder.design, _builder.last_pose)
		PerfSpan.end("csp_drives")
	PerfSpan.begin("csp_glow")
	_update_glow(main, lat, lon, el, s_local)
	PerfSpan.end("csp_glow")
	if _ha_poll >= _HA_POLL_S:
		_ha_poll = 0.0
		PerfSpan.begin("csp_ha")
		_service_ha(main)
		PerfSpan.end("csp_ha")


func _update_glow(main: Node, lat: float, lon: float, el: float, s_local: Vector3) -> void:
	if el <= 0.0:
		dni_now = 0.0
		focus = 0.0
		_builder.set_glow_focus(0.0)
		return
	var hour: float = float(main.get("day_time")) if main.get("day_time") != null else 12.0
	var month: int = clampi(int(main.get("month")), 1, 12) if main.get("month") != null else 6
	var day: int = clampi(int(main.get("day")), 1, 31) if main.get("day") != null else 15
	var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, get_node_or_null("/root/WeatherService"))
	dni_now = CspTroughSource.dni_wm2(el, weather)
	var d := _builder.design
	var eta_design := maxf(float(d.get("eta_capture", 0.0)), 1e-4)
	# The efficiency at this sun, in the mount's own frame (cached per sun
	# direction on the design's shared table; a new angle is traced live, in
	# chunks, never in one go).
	var eta := CspLabSite.optical_eff_at(d, s_local, lat, true)
	var dni_design := maxf(float(d.get("dni", 900.0)), 1.0)
	focus = clampf((dni_now / dni_design) * (eta / eta_design), 0.0, 1.3)
	_builder.set_glow_focus(focus)


## Push the drives to Home Assistant, as the record's csplab_ha asks.
func _service_ha(main: Node) -> void:
	var prop := get_parent()
	var pid := str(prop.get("prop_id")) if prop != null and prop.get("prop_id") != null else ""
	if pid.is_empty():
		return
	var rec := PlacedPropService.get_prop_record(main, pid)
	var cfg: Dictionary = rec.get("csplab_ha", {}) as Dictionary
	if cfg.is_empty() or not bool(cfg.get("enabled", false)):
		ha_status = "Not sending to Home Assistant."
		return
	var c := CspLabActuators.normalized(cfg)
	var ha := get_node_or_null("/root/HomeAssistant")
	if ha == null or not ha.has_method("is_authed") or not bool(ha.call("is_authed")):
		ha_status = "Home Assistant isn't connected (Settings → Home Assistant)."
		return
	var force := str(c["mode"]) == "always"
	if not force:
		var sm := get_node_or_null("/root/SimMode")
		if sm != null and sm.has_method("should_run_realworld_actions") and not bool(sm.call("should_run_realworld_actions")):
			ha_status = "Waiting for Live mode (the real clock) to send."
			return
	var due := CspLabActuators.due(c, channels, ha_sent, _ha_since)
	if due.is_empty():
		if ha_status.is_empty() or not ha_status.begins_with("Sent"):
			ha_status = "Connected; nothing has moved past the deadband yet."
		return
	# A big field: the biggest moves first, the rest on the next pass (a
	# second later, not after another min interval).
	var backlog := due.size() > MAX_HA_SENDS
	if backlog:
		due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _ha_change(a) > _ha_change(b))
		due = due.slice(0, MAX_HA_SENDS)
	var names: Array = []
	for dv in due:
		var dd: Dictionary = dv
		var call: Dictionary = dd["call"]
		if call.is_empty():
			_ha_errors += 1
			continue
		ha.call("call_service", str(call["domain"]), str(call["service"]), str(dd["entity_id"]),
			call["data"] as Dictionary, true)
		ha_sent[str(dd["entity_id"])] = float(dd["value"])
		ha_sends += 1
		names.append("%s %.1f" % [str(dd["entity_id"]), float(dd["value"])])
	if not backlog:
		_ha_since = 0.0
	if names.size() > 4:
		ha_status = "Sent %d drives (%s …)%s." % [names.size(), ", ".join(PackedStringArray(names.slice(0, 3))),
			"; more next second" if backlog else ""]
	else:
		ha_status = "Sent %s." % ", ".join(PackedStringArray(names))


func _ha_change(dv: Dictionary) -> float:
	var eid := str(dv["entity_id"])
	if not ha_sent.has(eid):
		return INF
	return absf(float(dv["value"]) - float(ha_sent[eid]))


## The angles as a short line ("azimuth 183.2°, elevation 51.0°").
func angles_line(max_n: int = 4) -> String:
	var parts: Array = []
	for i in mini(channels.size(), max_n):
		var ch: Dictionary = channels[i]
		parts.append("%s %.1f°" % [str(ch["label"]).to_lower(), float(ch["deg"])])
	if channels.size() > max_n:
		parts.append("… %d drives" % channels.size())
	return ", ".join(PackedStringArray(parts)) if not parts.is_empty() else "no drives (it doesn't track)"

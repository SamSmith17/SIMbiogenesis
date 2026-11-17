class_name EspLabRuntime
extends Node

## A placed ESP board's twin, running in the world: once a second it reads
## every entity of the board's design (EspSim) at the prop's spot and the sim
## clock, through an EspWorldProbe that also sees:
##   people within a sensor's range (the NPC dots + the player);
##   the ground or water under a distance sensor (a ray straight down from
##   the sensor's point on the model, the board's own body excluded);
##   the graph items its parts are bound to (EspBindings: a tank's level, a
##   load's power, a relay's load).
## When the board's graph node (an appliance drawing the board's few watts)
## is off, or the site's AC is down, every entity is unavailable, as a real
## board with no power is.
##
## The readings are kept in `latest` (entity_id -> {text, value, available})
## and shown on a label over the stake.

const NODE_NAME := "EspLabRuntime"
const POLL_S := 1.0
const RAY_MAX_M := 6.0
const LABEL_LINES := 6

var latest := {}
var powered := true
var _poll := POLL_S
var _prop: Node3D = null
var _prop_id := ""
var _spec_key := ""
var _design: Dictionary = {}
var _probe: EspWorldProbe = null
var _label: Label3D = null
var _dist_point := Vector3.INF
var _body_rids: Array = []


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if not EspBuilder.handles(str(rec.get("model_id", ""))) or prop.get_node_or_null(NODE_NAME) != null:
		return
	var rt := EspLabRuntime.new()
	rt.name = NODE_NAME
	prop.add_child(rt)


static func of(prop: Node) -> EspLabRuntime:
	if prop == null:
		return null
	return prop.get_node_or_null(NODE_NAME) as EspLabRuntime


## The board's model under a placed prop (PlacedProp renames it ModelRoot).
static func board_model(prop: Node) -> Node3D:
	if prop == null:
		return null
	var m := prop.get_node_or_null("ModelRoot") as Node3D
	if m != null and m.has_meta("esp_board"):
		return m
	for n in prop.find_children("*", "Node3D", true, false):
		if n.has_meta("esp_board"):
			return n as Node3D
	return null


func design() -> Dictionary:
	return _design


func probe() -> EspWorldProbe:
	return _probe


func _ready() -> void:
	add_to_group("esplab_runtimes")  # ScadaHub.ESP_GROUP
	call_deferred("_bind")


func _main() -> Node:
	return get_tree().current_scene if get_tree() != null else null


func _bind() -> void:
	_prop = get_parent() as Node3D
	if _prop == null:
		return
	_prop_id = str(_prop.get("prop_id")) if "prop_id" in _prop else ""
	var main := _main()
	var rec := PlacedPropService.get_prop_record(main, _prop_id) if main != null else {}
	var spec: Dictionary = rec.get("esp_spec", {}) as Dictionary if rec.get("esp_spec") is Dictionary else {}
	_design = EspDesign.solve(spec)
	_spec_key = EspSpec.key_of(EspSpec.resolve(spec))
	_probe = EspWorldProbe.for_main(main, _prop.global_position)
	var gv := ServiceLocator.graph()
	if gv != null and is_instance_valid(gv):
		_probe.graph_model = gv.get("model")
	_probe.boot_h = _now_h() - 0.25 - NpcHash.unit01(_prop_id, "boot") * 2.0
	_probe.people_fn = _people_near
	_probe.distance_fn = _distance_down
	# Where the model put its distance sensor (the first one).
	_dist_point = Vector3.INF
	var model := board_model(_prop)
	if model != null and model.has_meta("distance_points"):
		var dp: Dictionary = model.get_meta("distance_points")
		for k in dp:
			_dist_point = (model as Node3D).global_transform * (dp[k] as Vector3)
			break
	_body_rids.clear()
	for b in _prop.find_children("*", "CollisionObject3D", true, false):
		_body_rids.append((b as CollisionObject3D).get_rid())
	_ensure_label(model)
	_poll = POLL_S


func _now_h() -> float:
	var main := _main()
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	return float(Time.get_unix_time_from_system()) / 3600.0


func _ensure_label(model: Node) -> void:
	if _label != null and is_instance_valid(_label):
		return
	_label = Label3D.new()
	_label.name = "Readings"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 28
	_label.pixel_size = 0.0018
	_label.outline_size = 6
	_label.modulate = Color(0.8, 0.95, 1.0)
	_label.visibility_range_end = 28.0
	_label.position = Vector3(0, float(model.get_meta("label_y", 1.55)) if model != null else 1.55, 0)
	# On the prop (a Node3D): under this plain Node it would sit at the origin.
	_prop.add_child(_label)


func _exit_tree() -> void:
	if _label != null and is_instance_valid(_label):
		_label.queue_free()


func readings_label() -> Label3D:
	return _label


func _process(delta: float) -> void:
	_poll += delta
	if _poll < POLL_S:
		return
	_poll = 0.0
	if _prop == null or not is_instance_valid(_prop):
		return
	PerfSpan.begin("esp_runtime")
	_refresh()
	PerfSpan.end("esp_runtime")


func _refresh() -> void:
	var main := _main()
	var rec := PlacedPropService.get_prop_record(main, _prop_id) if main != null else {}
	var spec: Dictionary = rec.get("esp_spec", {}) as Dictionary if rec.get("esp_spec") is Dictionary else {}
	var key := EspSpec.key_of(EspSpec.resolve(spec))
	if key != _spec_key:
		_bind()
	powered = _is_powered(main, rec)
	var t := _now_h()
	var src := _probe.source()
	var node := str(_design.get("node", ""))
	var out := {}
	for e in _design.get("entities", []):
		var r: Dictionary
		if powered:
			r = EspSim.reading(e, EspSim.unit_key(node, e), t, src)
		else:
			r = {"value": NAN, "t": t, "available": false}
		out[str(e["entity_id"])] = {"text": EspSim.format(e, r), "value": r["value"], "available": r["available"]}
	latest = out
	_update_label()


## The graph node this board is (its load), "" when it has none.
func graph_item_id() -> String:
	var main := _main()
	var rec := PlacedPropService.get_prop_record(main, _prop_id) if main != null else {}
	return str(rec.get("graph_item_id", ""))


func _is_powered(main: Node, rec: Dictionary) -> bool:
	var gid := str(rec.get("graph_item_id", ""))
	if gid == "":
		return true
	if not PlacedLightPower.graph_item_on(gid):
		return false
	if PlacedLightPower.graph_has_power_hardware():
		return PlacedLightPower.ac_available(main)
	return true


func _update_label() -> void:
	if _label == null:
		return
	var lines := PackedStringArray()
	lines.append(str(_design.get("friendly", "ESP board")))
	if not powered:
		lines.append("no power")
	else:
		var n := 0
		for e in _design.get("entities", []):
			if str(e["iid"]) == "" or n >= LABEL_LINES:
				continue
			var lv: Dictionary = latest.get(str(e["entity_id"]), {})
			lines.append("%s  %s" % [e["name"], str(lv.get("text", ""))])
			n += 1
	_label.text = "\n".join(lines)
	_label.modulate = Color(0.8, 0.95, 1.0) if powered else Color(1.0, 0.55, 0.45)


## People (NPCs and the player) within r metres of p, on the ground plane.
func _people_near(p: Vector3, r: float, _t: float) -> int:
	var n := 0
	var gv := ServiceLocator.graph()
	if gv != null and is_instance_valid(gv) and gv.has_method("npc_population_bridge"):
		var bridge: Object = gv.call("npc_population_bridge")
		if bridge != null and bridge.has_method("agent_dots"):
			for d in bridge.call("agent_dots"):
				var dp: Variant = (d as Dictionary).get("pos", null)
				var q := Vector2.INF
				if dp is Vector3:
					q = Vector2((dp as Vector3).x, (dp as Vector3).z)
				elif dp is Vector2:
					q = dp
				if q != Vector2.INF and q.distance_to(Vector2(p.x, p.z)) <= r:
					n += 1
	var main := _main()
	var pl := main.get_node_or_null("Player") as Node3D if main != null else null
	if pl != null and Vector2(pl.global_position.x, pl.global_position.z).distance_to(Vector2(p.x, p.z)) <= r:
		n += 1
	return n


## A distance sensor's echo: straight down from its point to the first
## surface (ground, water, a placed thing), the board's own body excluded.
func _distance_down(_t: float) -> float:
	if _dist_point == Vector3.INF or _prop == null or not _prop.is_inside_tree():
		return 1.0
	var space := _prop.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(_dist_point, _dist_point + Vector3.DOWN * RAY_MAX_M)
	q.exclude = _body_rids
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		# No collider below (a scene with no ground collision): the terrain.
		var main := _main()
		var gy := TerrainSurfaceQuery.ground_height_at(main, _dist_point.x, _dist_point.z) if main != null else NAN
		return _dist_point.y - gy if not is_nan(gy) else RAY_MAX_M
	return _dist_point.distance_to(hit["position"])

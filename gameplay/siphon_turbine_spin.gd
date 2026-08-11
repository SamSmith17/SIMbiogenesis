class_name SiphonTurbineSpin
extends Node3D

## Spins a placed hydro turbine's runner from live graph telemetry (same spirit
## as WindTurbineSpin). Attached by PlacedPropRuntime for any hydro-turbine
## model (ModelCatalog.is_hydro_turbine) or record.kind == "siphon_hydro".
##
## Two things are model-dependent and must NOT be assumed:
##  - the runner NODE (catalog `turbine_node`, else a name/size heuristic), and
##  - the runner AXIS. The siphon hydroturbine spins about model local +Z, but
##    the PowerSpout's Pelton wheel spins about local ±X — a wrong axis reads
##    as the wheel tumbling end-over-end rather than turning. A model may state
##    `spin_axis`; otherwise it is MEASURED as the thinnest extent of the
##    runner's own mesh AABB (a Pelton/propeller disc is flat perpendicular to
##    its axis), the same measure-don't-hardcode approach CspTroughTracker uses
##    for its rest pose.

const _SMOOTH_TAU := 0.6
const _MAX_OMEGA := SiphonHydraulics.OMEGA_AT_RATED * 1.25
const _POLL_S := 0.35
## Skip transform writes when parked (avoids perpetual dirty transforms).
const _PARK_EPS := 0.02

var graph_item_id: String = ""
var turbine_node_name: String = ""
## "x" | "y" | "z" from the model catalog; "" measures the axis from geometry.
var spin_axis_hint: String = ""
## Runner pitch-circle diameter (m) for rpm→ω when the graph reports rpm; 0 =
## unused (the reported rpm IS the shaft speed, so this is informational only).
var _last_rpm: float = 0.0

var _turbine: Node3D = null
var _t0: Transform3D = Transform3D.IDENTITY
var _axis_p: Vector3 = Vector3(0.0, 0.0, 1.0)
var _center_p: Vector3 = Vector3.ZERO
var _angle: float = 0.0
var _omega: float = 0.0
var _target_omega: float = 0.0
var _poll_acc: float = 999.0
var _ready_ok := false
var _sgv: Node = null
var _parked := true

## Tailwater jet at the tailrace while the turbine is flowing (penstock kinds —
## a siphon's water leaves via its culvert, which has its own discharge VFX).
## Reuses ConduitDischargeVfx; flow comes from the same 0.35 s spec poll.
var _tail_vfx: ConduitDischargeVfx = null
var _tail_q_lps: float = 0.0
var _tail_enabled := false
var _tail_mouth_local := Vector3.INF   # ModelRoot-local tailrace position
var _tail_out_local := Vector3.FORWARD


func configure(item_id: String, turbine_name: String = "",
		axis_hint: String = "") -> void:
	graph_item_id = item_id
	turbine_node_name = turbine_name
	spin_axis_hint = axis_hint.to_lower().strip_edges()


func _ready() -> void:
	call_deferred("_bind_turbine")


func _bind_turbine() -> void:
	var model_root := _find_model_root()
	if model_root == null:
		return
	_turbine = _resolve_turbine(model_root)
	if _turbine == null or _turbine.get_parent() == null:
		return
	var parent := _turbine.get_parent() as Node3D
	if parent == null:
		return
	var model_basis := model_root.global_transform.basis
	var local_axis := _resolve_spin_axis_local()
	var world_axis := (model_basis * local_axis).normalized()
	if world_axis.length_squared() < 0.0001:
		world_axis = Vector3.UP
	var parent_gt := parent.global_transform
	_axis_p = (parent_gt.basis.inverse() * world_axis).normalized()
	if _axis_p.length_squared() < 0.0001:
		_axis_p = Vector3(0.0, 0.0, 1.0)
	var center_world := _group_world_center(_turbine)
	_center_p = parent_gt.affine_inverse() * center_world
	_t0 = _turbine.transform
	_ready_ok = true


func _process(delta: float) -> void:
	if not _ready_ok or not is_instance_valid(_turbine):
		return
	_poll_acc += delta
	if _poll_acc >= _POLL_S:
		_poll_acc = 0.0
		_refresh_target()
	_update_tailwater(delta)
	var k := 1.0 - exp(-delta / maxf(_SMOOTH_TAU, 0.01))
	_omega = lerpf(_omega, _target_omega, clampf(k, 0.0, 1.0))
	if absf(_omega) < _PARK_EPS and absf(_target_omega) < _PARK_EPS:
		if not _parked:
			_parked = true
			_omega = 0.0
			# One last rest pose write.
			_turbine.transform = _t0
		return
	_parked = false
	_angle = wrapf(_angle + _omega * delta, -TAU, TAU)
	var rot := Basis(_axis_p, _angle)
	_turbine.transform = Transform3D(rot, _center_p - rot * _center_p) * _t0


func _refresh_target() -> void:
	_target_omega = 0.0
	if graph_item_id.is_empty():
		return
	if _sgv == null or not is_instance_valid(_sgv):
		_sgv = _system_graph_view(_main_node())
	if _sgv == null:
		return
	var model = _sgv.get("model")
	if model == null or not model.has_method("get_item"):
		return
	var item: Dictionary = model.get_item(graph_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Tailwater: penstock kinds discharge at the machine (a siphon's water
	# leaves via its culvert, whose mouth has its own jet). Re-checked per poll
	# so the kind selector flips the effect live.
	_tail_q_lps = maxf(float(specs.get("live_q_lps", 0.0)), 0.0)
	_tail_enabled = bool(HydroSource.kind_meta(
			str(specs.get("turbine_kind", "siphon"))).get("has_penstock", false))
	# Nozzle-governed impulse runners (PowerSpout Pelton) publish a real shaft
	# speed derived from the jet (PeltonPhysics); use it rather than re-deriving
	# ω from the siphon rotor curve, whose 5 kW reference badly overstates a
	# few-hundred-watt pico Pelton.
	var rpm := float(specs.get("live_rpm", 0.0))
	if rpm > 0.01:
		_last_rpm = rpm
		_target_omega = clampf(rpm * TAU / 60.0, 0.0, _MAX_OMEGA)
		return
	_last_rpm = 0.0
	var pe_w := float(specs.get("live_pe_w", 0.0))
	if pe_w <= 0.0:
		var power_w := float(specs.get("live_power_w", 0.0))
		if power_w <= 0.0:
			power_w = float(specs.get("current_output_kw", 0.0)) * 1000.0
		_target_omega = clampf(SiphonHydraulics.omega_from_power_w(power_w,
				float(specs.get("max_power_w", 0.0))), 0.0, _MAX_OMEGA)
	else:
		_target_omega = clampf(SiphonHydraulics.omega_from_pe_w(pe_w), 0.0, _MAX_OMEGA)


## Tailwater jet at the tailrace port while flowing — the visual the culvert
## outlet already has (ConduitDischargeVfx), attached to the machine itself.
func _update_tailwater(delta: float) -> void:
	if not _tail_enabled or (_tail_vfx == null and _tail_q_lps <= ConduitDischargeVfx.Q_MIN_LPS):
		# Never flowed (or not a tailwater kind) — don't spawn a particle node.
		if _tail_vfx != null and not _tail_enabled:
			_tail_vfx.set_flow(delta, 0.0, _tail_vfx.global_position, Vector3.DOWN)
		return
	if not is_finite(_tail_mouth_local.x):
		_resolve_tailrace_port()
		if not is_finite(_tail_mouth_local.x):
			_tail_enabled = false   # no port to speak of; stop trying
			return
	var model_root := _find_model_root()
	if model_root == null:
		return
	if _tail_vfx == null:
		_tail_vfx = ConduitDischargeVfx.new()
		_tail_vfx.name = "TailwaterVfx"
		# Sibling of ModelRoot under PlacedProp — real-world metres, immune to
		# any baked GLB scale (the CSP light/card lesson).
		var host := get_parent()
		if host == null:
			host = self
		host.add_child(_tail_vfx)
	var gt := model_root.global_transform
	var mouth := gt * _tail_mouth_local
	var dir := (gt.basis * _tail_out_local)
	_tail_vfx.set_flow(delta, _tail_q_lps, mouth, dir)


## Tailrace ("res_out_0") port in ModelRoot-local space, from the same resolver
## the conduit anchors use (instance override > catalog file > built-ins).
func _resolve_tailrace_port() -> void:
	var prop := get_parent()
	if prop == null:
		return
	var prop_id := str(prop.get("prop_id")) if "prop_id" in prop else ""
	var ports := ConnectionPortDefs.resolve_ports_for_prop(_main_node(), prop_id)
	for p_v in ports:
		var p: Dictionary = p_v
		if str(p.get("handle_id", "")) != "res_out_0":
			continue
		_tail_mouth_local = Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)),
				float(p.get("z", 0.0)))
		_tail_out_local = Vector3(float(p.get("nx", 0.0)), float(p.get("ny", -0.4)),
				float(p.get("nz", 1.0)))
		return


func _find_model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	if mr != null:
		return mr
	return p as Node3D


## Runner axis in MODEL-ROOT local space. An explicit catalog `spin_axis` wins;
## otherwise measure it — a runner disc (Pelton wheel, propeller) is flat, so
## its own mesh AABB's thinnest extent IS the shaft axis. Falls back to the
## historical +Z, keeping the siphon hydroturbine byte-identical.
func _resolve_spin_axis_local() -> Vector3:
	match spin_axis_hint:
		"x", "+x", "-x":
			return Vector3.RIGHT
		"y", "+y", "-y":
			return Vector3.UP
		"z", "+z", "-z":
			return Vector3.BACK
	var measured := _measure_runner_axis_local()
	if measured.length_squared() > 0.0001:
		return measured
	return Vector3(0.0, 0.0, 1.0)


## Thinnest-extent axis of the runner's own mesh AABB, expressed in model-root
## space by composing the local transforms up the chain (NOT global_transform —
## this runs from a deferred bind, where the global cache can still be stale;
## same technique as CspTroughTracker._relative_to_pivot).
func _measure_runner_axis_local() -> Vector3:
	if _turbine == null:
		return Vector3.ZERO
	var mi := _turbine as MeshInstance3D
	if mi == null:
		for n in _turbine.find_children("*", "MeshInstance3D", true, false):
			if (n as MeshInstance3D).mesh != null:
				mi = n as MeshInstance3D
				break
	if mi == null or mi.mesh == null:
		return Vector3.ZERO
	var sz := mi.mesh.get_aabb().size
	if sz.x <= 0.0 or sz.y <= 0.0 or sz.z <= 0.0:
		return Vector3.ZERO
	# A disc must be clearly flatter on one axis; an equilateral blob has no
	# meaningful shaft and should fall back rather than pick a coin-flip axis.
	var thin := Vector3.BACK
	if sz.x <= sz.y and sz.x <= sz.z:
		thin = Vector3.RIGHT
	elif sz.y <= sz.x and sz.y <= sz.z:
		thin = Vector3.UP
	var extents := [sz.x, sz.y, sz.z]
	extents.sort()
	if extents[0] > extents[1] * 0.75:
		return Vector3.ZERO
	# Compose mesh-local → model-root through the parent chain.
	var b := Basis.IDENTITY
	var n2: Node = mi
	var root := _find_model_root()
	while n2 != null and n2 != root:
		if n2 is Node3D:
			b = (n2 as Node3D).transform.basis * b
		n2 = n2.get_parent()
	return (b * thin).normalized()


func _resolve_turbine(model_root: Node3D) -> Node3D:
	var prefer := [
		turbine_node_name, "propeller", "Propeller", "rotor", "Rotor",
		"spindle", "Spindle", "blade", "Blade", "impeller", "Impeller",
	]
	for name in prefer:
		if str(name).is_empty():
			continue
		var named := model_root.find_child(str(name), true, false)
		if named is Node3D:
			return named as Node3D
	var best: Node3D = null
	var best_vol := INF
	for n in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var vol := absf(aabb.size.x * aabb.size.y * aabb.size.z)
		if vol > 1e-8 and vol < best_vol:
			best_vol = vol
			best = mi
	return best


func _group_world_center(group: Node3D) -> Vector3:
	if group is MeshInstance3D:
		var mi := group as MeshInstance3D
		if mi.mesh != null:
			return (mi.global_transform * mi.mesh.get_aabb()).get_center()
	var aabb := AABB()
	var found := false
	for node in group.find_children("*", "MeshInstance3D", true, false):
		var mi2 := node as MeshInstance3D
		if mi2.mesh == null:
			continue
		var box: AABB = mi2.global_transform * mi2.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		return group.global_position
	return aabb.get_center()


func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene


func _system_graph_view(main: Node) -> Node:
	if main == null:
		return null
	var sgv := ServiceLocator.graph()
	if sgv == null:
		sgv = main.find_child("SystemGraphView", true, false)
	return sgv

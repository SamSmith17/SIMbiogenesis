class_name StreamIntakeFlow
extends Node3D

## Water arriving at a placed stream/spring intake, driven by the live supply the
## flow engine resolves onto the intake's graph node (`live_supply_lps`).
##
## The 3D end of the tapped-source loop was silent: you could route a penstock,
## watch the turbine spin and the tailwater fall, and the thing that was
## supposedly feeding all of it just sat there — so a dry spring and a spring in
## full spate looked identical in the world.
##
## Two elements, because a spring reads as neither alone: a falling inflow into
## the open sump, and a shallow water plane inside the box whose level rises with
## the flow. Deliberately cheap — this is scenery for a 0.7 m prop that a player
## mostly sees from a distance.
##
## Polling mirrors SiphonTurbineSpin: 0.35 s against the graph model, no per-frame
## model lookups, and it degrades to "no water" whenever the node cannot be
## resolved rather than guessing.

const _POLL_S := 0.35
const _SMOOTH_TAU := 0.8
## Supply (L/s) that reads as a "full" spring. A tapped creek runs a few L/s; the
## culvert class's 12 L/s reference would make every intake look like a trickle.
const _Q_REF_LPS := 4.0
const _Q_MIN_LPS := 0.02
const _AMOUNT_MAX := 90

## Sump interior, from StreamIntakeBuilder's own constants so the water can never
## drift out of the box it is supposed to be sitting in.
const _POOL_INSET := 0.055
const _POOL_MIN_Y := 0.06
const _POOL_MAX_Y := 0.30

var graph_item_id: String = ""

var _particles: GPUParticles3D
var _pmat: ParticleProcessMaterial
var _pool: MeshInstance3D
var _pool_mat: StandardMaterial3D

var _q_lps := 0.0        ## smoothed, for display
var _q_target := 0.0     ## last polled
var _poll_acc := 999.0
var _sgv: Node = null


func configure(item_id: String) -> void:
	graph_item_id = item_id


func _ready() -> void:
	_build()
	set_process(true)


func _build() -> void:
	# Inflow: droplets falling into the open top of the sump. World coords so the
	# arc keeps falling under real gravity however the prop is yawed.
	_particles = GPUParticles3D.new()
	_particles.name = "InflowParticles"
	_particles.amount = _AMOUNT_MAX
	_particles.amount_ratio = 0.0
	_particles.lifetime = 0.55
	_particles.emitting = false
	_particles.local_coords = false
	_particles.visibility_aabb = AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	_pmat = ParticleProcessMaterial.new()
	_pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_pmat.emission_box_extents = Vector3(
			StreamIntakeBuilder.WIDTH_M * 0.30, 0.01,
			StreamIntakeBuilder.DEPTH_M * 0.22)
	_pmat.direction = Vector3.DOWN
	_pmat.spread = 8.0
	_pmat.gravity = Vector3(0, -9.8, 0)
	_pmat.scale_min = 1.0
	_pmat.scale_max = 1.0
	_particles.process_material = _pmat
	var q := QuadMesh.new()
	q.size = Vector2(0.008, 0.008)
	var qm := StandardMaterial3D.new()
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.albedo_color = Color(0.78, 0.90, 1.0, 0.8)
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = qm
	_particles.draw_pass_1 = q
	# Emit just above the rim so the fall is visible before it lands.
	_particles.position = Vector3(0, StreamIntakeBuilder.BODY_H_M + 0.18, 0)
	add_child(_particles)

	# Standing water inside the sump.
	_pool = MeshInstance3D.new()
	_pool.name = "Pool"
	var plane := PlaneMesh.new()
	plane.size = Vector2(
			maxf(StreamIntakeBuilder.WIDTH_M - _POOL_INSET * 2.0, 0.05),
			maxf(StreamIntakeBuilder.DEPTH_M - _POOL_INSET * 2.0, 0.05))
	_pool.mesh = plane
	_pool_mat = StandardMaterial3D.new()
	_pool_mat.albedo_color = Color(0.16, 0.34, 0.42, 0.88)
	_pool_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pool_mat.metallic = 0.25
	_pool_mat.roughness = 0.12
	# Seen from directly above as often as not, and it is a thin plate.
	_pool_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pool.material_override = _pool_mat
	_pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pool.visible = false
	add_child(_pool)


func _process(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc >= _POLL_S:
		_poll_acc = 0.0
		_refresh_target()
	_q_lps = lerpf(_q_lps, _q_target,
			clampf(1.0 - exp(-delta / _SMOOTH_TAU), 0.0, 1.0))
	_apply()


func _refresh_target() -> void:
	_q_target = 0.0
	if graph_item_id.is_empty():
		_resolve_graph_item_id()
	if graph_item_id.is_empty():
		return
	if _sgv == null or not is_instance_valid(_sgv):
		_sgv = _system_graph_view()
	if _sgv == null:
		return
	var model = _sgv.get("model")
	if model == null or not model.has_method("get_item"):
		return
	var item: Dictionary = model.get_item(graph_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	_q_target = maxf(float(specs.get("live_supply_lps", 0.0)), 0.0)


func _apply() -> void:
	var t := clampf(_q_lps / _Q_REF_LPS, 0.0, 1.0)
	var running := _q_lps > _Q_MIN_LPS
	if _particles != null:
		_particles.emitting = running
		if running:
			_particles.amount_ratio = lerpf(0.18, 1.0, t)
			_pmat.initial_velocity_min = lerpf(0.15, 0.8, t)
			_pmat.initial_velocity_max = lerpf(0.4, 1.6, t)
	if _pool != null:
		_pool.visible = running
		if running:
			# Level rises with flow — a spring in spate fills its box.
			_pool.position = Vector3(0.0, lerpf(_POOL_MIN_Y, _POOL_MAX_Y, t), 0.0)
			var c := _pool_mat.albedo_color
			c.a = lerpf(0.70, 0.92, t)
			_pool_mat.albedo_color = c


## Re-read the graph item id off the prop record.
##
## Needed because create_penstock_intake_at PLACES the prop first and patches
## `graph_item_id` onto its record afterwards — so the runtime is attached with an
## empty id and, without this, never showed water at all. Resolving lazily per
## poll also survives a re-bind, and costs one dictionary lookup every 0.35 s.
func _resolve_graph_item_id() -> void:
	var prop := get_parent() as PlacedProp
	if prop == null or prop.prop_id.is_empty():
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var rec := PlacedPropService.get_prop_record(tree.current_scene, prop.prop_id)
	graph_item_id = str(rec.get("graph_item_id", ""))


func _system_graph_view() -> Node:
	var sgv := ServiceLocator.graph()
	if sgv != null:
		return sgv
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.find_child("SystemGraphView", true, false)

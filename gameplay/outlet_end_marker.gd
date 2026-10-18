class_name OutletEndMarker
extends Interactable

## The grabbable END of a siphon's draft pipe (its culvert outlet) in the
## world: an orange ring round the pipe mouth with a short cone pointing the
## way the water leaves. The outlet NODE has no prop, so until this existed
## nothing in 3D could take hold of the pipe's end — a drag on the pipe there
## only ever INSERTED A WAYPOINT, and the exit could be moved only from the
## Lab's cut or the Site Plan.
##
## GrabController's relocatable-marker contract (the J string-light pins):
## Ctrl/Alt + aim focuses it (the crosshair names it, it pulses), LMB + drag
## carries it along the terrain under the crosshair, release commits through
## `SystemGraphView.move_siphon_outlet` — the outlet node, the culvert's far
## end and the physics' exit height move together and the pipe rebuilds to
## the new mouth, a little under the surface where it daylights. A click
## opens the Hydro Lab on the siphon. Owned and positioned by ConduitManager
## (`_update_outlet_marker`), parented to Main and `top_level`, so it stays
## visible in first person while the x-ray pipe itself is hidden.

const RING_COLOR := Color(1.0, 0.56, 0.12, 0.95)
const HOT_COLOR := Color(1.0, 0.85, 0.35, 1.0)
const DRAG_COLOR := Color(0.55, 0.95, 1.0, 1.0)
## Below the ground where the mouth daylights (the Lab's convention).
const INVERT_UNDER_GROUND_M := 0.3
## How far away the end can be grabbed from (the pipe runs down the hill).
const GRAB_DISTANCE_M := 400.0

var conn_id: String = ""
var sink_id: String = ""
var siphon_id: String = ""

var _rig: Node3D = null
var _ring: MeshInstance3D = null
var _cone: MeshInstance3D = null
var _body: Area3D = null
var _mat: StandardMaterial3D = null
var _mouth: Vector3 = Vector3.INF
var _dir: Vector3 = Vector3.FORWARD
var _pipe_r: float = 0.1
var _hot := false
var _dragging := false
var _pulse_t := 0.0
var _last_commit: Dictionary = {}


func _ready() -> void:
	super._ready()
	prompt = "Draft outlet — drag to move the pipe's end · click: Hydro Lab"
	max_distance = 2000.0
	top_level = true
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = RING_COLOR
	_mat.no_depth_test = true
	_mat.render_priority = 12
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rig = Node3D.new()
	_rig.name = "Rig"
	add_child(_rig)
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.2
	torus.outer_radius = 0.26
	torus.rings = 24
	torus.ring_segments = 10
	_ring.mesh = torus
	_ring.material_override = _mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_ring)
	_cone = MeshInstance3D.new()
	_cone.name = "Cone"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0
	cyl.bottom_radius = 0.09
	cyl.height = 0.32
	cyl.radial_segments = 12
	cyl.rings = 1
	_cone.mesh = cyl
	_cone.material_override = _mat
	_cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cone.position = Vector3(0.0, 0.34, 0.0)
	_rig.add_child(_cone)
	_body = Area3D.new()
	_body.name = "EndBody"
	_body.collision_layer = 1
	_body.collision_mask = 0
	_body.monitoring = false
	_body.monitorable = false
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.6
	shape.shape = sph
	_body.add_child(shape)
	add_child(_body)
	_apply_size()


## Where the pipe ends: the culvert's last sample, its exit direction and the
## pipe's radius. Called by ConduitManager after every rebuild; ignored while
## the player is carrying the marker.
func set_mouth(mouth: Vector3, dir: Vector3, pipe_r: float) -> void:
	_mouth = mouth
	if dir.length_squared() > 1e-6:
		_dir = dir.normalized()
	_pipe_r = maxf(pipe_r, 0.05)
	_apply_size()
	if not _dragging:
		sync_position()


func _apply_size() -> void:
	if _ring == null:
		return
	var r := maxf(_pipe_r + 0.12, 0.25)
	var torus := _ring.mesh as TorusMesh
	torus.inner_radius = r - 0.045
	torus.outer_radius = r + 0.045
	var sph := (_body.get_child(0) as CollisionShape3D).shape as SphereShape3D
	sph.radius = maxf(r + 0.35, 0.6)
	# Ring axis along the pipe, cone pointing out of the mouth.
	var y := _dir
	var x := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	x = (x - y * x.dot(y)).normalized()
	var z := x.cross(y).normalized()
	_rig.transform = Transform3D(Basis(x, y, z), Vector3.ZERO)


func sync_position() -> void:
	if is_finite(_mouth.x):
		global_position = _mouth


func is_dragging() -> bool:
	return _dragging


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	_pulse_t += delta
	if _rig == null:
		return
	if _hot or _dragging:
		var k := 1.0 + 0.14 * sin(_pulse_t * 7.0)
		_rig.scale = Vector3.ONE * k
	elif _rig.scale != Vector3.ONE:
		_rig.scale = Vector3.ONE


func _apply_highlight(on: bool) -> void:
	_hot = on
	if _mat != null:
		_mat.albedo_color = DRAG_COLOR if _dragging else (HOT_COLOR if on else RING_COLOR)


func get_world_pick_aabb() -> AABB:
	var h := Vector3.ONE * maxf(_pipe_r + 0.5, 0.7)
	return AABB(global_position - h, h * 2.0)


# -- Interactable ------------------------------------------------------------

func interact(_player: Node) -> void:
	_open_lab()


# -- GrabController relocatable-marker contract ------------------------------

func grab_distance_m() -> float:
	return GRAB_DISTANCE_M


func world_drag_begin() -> void:
	_dragging = true
	_apply_highlight(_hot)


func world_drag_aim(camera: Camera3D) -> Variant:
	var main := _main_node()
	if main == null or camera == null:
		return null
	var hit := TerrainSurfaceQuery.raycast_ground_at_camera(main, camera)
	if hit.is_empty():
		return null
	return hit["position"]


func world_drag_preview(pos: Vector3) -> void:
	global_position = pos + Vector3.UP * 0.05


func world_drag_commit(pos: Vector3) -> void:
	_dragging = false
	_apply_highlight(_hot)
	var sgv := _graph_view()
	var soi := get_tree().root.get_node_or_null("SoiService")
	if sgv == null or soi == null or not soi.has_method("world_center") \
			or siphon_id.is_empty() or not sgv.has_method("move_siphon_outlet"):
		sync_position()
		return
	var c: Vector3 = soi.call("world_center")
	var main := _main_node()
	var g := TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z) if main != null else pos.y
	var site := Vector2(pos.x - c.x, pos.z - c.z)
	var elev := g - INVERT_UNDER_GROUND_M
	var ok := bool(sgv.call("move_siphon_outlet", siphon_id, site, elev))
	_last_commit = {"site": site, "elev": elev, "ok": ok}
	if ok and sgv.has_method("_show_toast"):
		sgv.call("_show_toast", "Draft outlet moved — the culvert follows it")
	if not ok:
		sync_position()


func world_drag_cancel() -> void:
	_dragging = false
	_apply_highlight(_hot)
	sync_position()


func world_drag_click() -> void:
	_open_lab()


func debug_summary() -> Dictionary:
	return {
		"conn_id": conn_id, "sink_id": sink_id, "siphon_id": siphon_id,
		"mouth": _mouth, "dir": _dir, "pos": global_position,
		"dragging": _dragging, "hot": _hot, "last_commit": _last_commit,
	}


func _open_lab() -> void:
	var sgv := _graph_view()
	if sgv == null or siphon_id.is_empty() or not sgv.has_method("open_siphon_lab"):
		return
	(sgv as CanvasItem).visible = true
	sgv.call("open_siphon_lab", siphon_id)


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _graph_view() -> Node:
	var main := _main_node()
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	return ui.get_node_or_null("SystemGraphView") if ui != null else null

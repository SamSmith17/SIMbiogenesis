class_name PondLevelHandle
extends Interactable

## The pond's MAX FILL LEVEL, grabbable in the world. One per still-water
## body (map ponds and carved ones alike): a ring floating at the pond's
## max fill height over its centroid with a vertical rod, and a pick body
## that is a thin SLAB over the whole water surface — so Ctrl/Alt-aiming
## anywhere on the pond takes hold of its surface, as asked ("select the pond
## surface and drag it upwards"). LMB + drag moves the level STRAIGHT UP OR
## DOWN (the crosshair ray's closest point to the vertical line through the
## handle), with a live readout "max fill +0.40 m above the basin rim ·
## capacity +12 kL"; release commits through TerrainLoader.set_pond_max_level,
## which raises the pond's spill height, its capacity (vertical wall above the
## basin — a dam — until a flood-fill outline lands) and the graph tank's
## rim. A click opens Pond settings. Owned by TerrainLoader
## (`_refresh_pond_level_handles`), parented to Main, `top_level`.

const RING_COLOR := Color(0.35, 0.78, 1.0, 0.92)
const HOT_COLOR := Color(0.75, 0.95, 1.0, 1.0)
const DRAG_COLOR := Color(1.0, 0.85, 0.35, 1.0)
const GRAB_DISTANCE_M := 600.0
## How far above the basin rim the dam can go.
const MAX_ABOVE_RIM_M := 15.0

var water_idx: int = -1
var tag: String = ""
var _loader: Node = null
var _centroid: Vector2 = Vector2.ZERO
var _rect: Rect2 = Rect2()
var _basin_rim: float = 0.0
var _max_y: float = 0.0
var _area_m2: float = 0.0
var _rig: Node3D = null
var _ring: MeshInstance3D = null
var _rod: MeshInstance3D = null
var _mat: StandardMaterial3D = null
var _body: Area3D = null
var _slab: BoxShape3D = null
var _label: Label3D = null
var _hot := false
var _dragging := false
var _drag_y: float = NAN
var _pulse_t := 0.0
var _last_commit: Dictionary = {}


func _ready() -> void:
	super._ready()
	prompt = "Pond surface — drag up/down: max fill level · click: Pond settings"
	max_distance = 3000.0
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
	torus.inner_radius = 0.9
	torus.outer_radius = 1.05
	torus.rings = 32
	torus.ring_segments = 8
	_ring.mesh = torus
	_ring.material_override = _mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_ring)
	_rod = MeshInstance3D.new()
	_rod.name = "Rod"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.04
	cyl.height = 1.6
	cyl.radial_segments = 8
	cyl.rings = 1
	_rod.mesh = cyl
	_rod.material_override = _mat
	_rod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_rod)
	_label = Label3D.new()
	_label.name = "Readout"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0009
	_label.font_size = 30
	_label.outline_size = 8
	_label.position = Vector3(0.0, 1.3, 0.0)
	_label.visible = false
	add_child(_label)
	_body = Area3D.new()
	_body.name = "SurfaceBody"
	_body.collision_layer = 1
	_body.collision_mask = 0
	_body.monitoring = false
	_body.monitorable = false
	var shape := CollisionShape3D.new()
	_slab = BoxShape3D.new()
	_slab.size = Vector3(2.0, 0.3, 2.0)
	shape.shape = _slab
	_body.add_child(shape)
	add_child(_body)


func configure(loader: Node, idx: int, p_tag: String) -> void:
	_loader = loader
	water_idx = idx
	tag = p_tag


## Where the pond is and how high its max fill stands. The slab covers the
## polygon's bounding rect at that height; the ring sits over the centroid.
func set_geometry(centroid: Vector2, rect: Rect2, basin_rim_y: float, max_y: float,
		area_m2: float, level_y: float = NAN) -> void:
	_centroid = centroid
	_rect = rect
	_basin_rim = basin_rim_y
	_max_y = max_y
	_area_m2 = area_m2
	if _slab != null:
		# The pick slab spans from the WATER SURFACE up to the max fill height
		# (plus a little), so aiming at the water takes the surface whatever
		# the level, and the body sits in the handle's frame (origin = max_y).
		var lo := (level_y if not is_nan(level_y) else max_y) - 0.15
		var hi := max_y + 0.15
		if lo > hi - 0.3:
			lo = hi - 0.3
		_slab.size = Vector3(maxf(rect.size.x, 2.0), hi - lo, maxf(rect.size.y, 2.0))
		_body.position = Vector3(rect.get_center().x - centroid.x, (lo + hi) * 0.5 - max_y,
				rect.get_center().y - centroid.y)
	if not _dragging:
		sync_position()
		_update_readout(_max_y)


func sync_position() -> void:
	global_position = Vector3(_centroid.x, _max_y, _centroid.y)


func max_level_y() -> float:
	return _max_y


func is_dragging() -> bool:
	return _dragging


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	_pulse_t += delta
	# Every still-water body on the map carries one of these; the ring shows
	# only while the player is SELECTING (Ctrl/Alt held — the J IK-sphere
	# rule), focused, or dragging. The pick slab is always live.
	var show := _hot or _dragging or ModifierKeys.selecting()
	if _rig != null:
		_rig.visible = show
		if _hot or _dragging:
			_rig.scale = Vector3.ONE * (1.0 + 0.1 * sin(_pulse_t * 6.0))
		elif _rig.scale != Vector3.ONE:
			_rig.scale = Vector3.ONE
	if _label != null:
		_label.visible = _hot or _dragging


func _apply_highlight(on: bool) -> void:
	_hot = on
	if _mat != null:
		_mat.albedo_color = DRAG_COLOR if _dragging else (HOT_COLOR if on else RING_COLOR)
	if on and not _dragging:
		_update_readout(_max_y)


func get_world_pick_aabb() -> AABB:
	var sz := Vector3(maxf(_rect.size.x, 2.0), 0.6, maxf(_rect.size.y, 2.0))
	var c := Vector3(_rect.get_center().x, global_position.y, _rect.get_center().y)
	return AABB(c - sz * 0.5, sz)


func _update_readout(y: float) -> void:
	if _label == null:
		return
	var above := y - _basin_rim
	var extra_l := maxf(above, 0.0) * _area_m2 * 1000.0
	if above <= 0.02:
		_label.text = "max fill = basin rim (%.2f m)" % y
	else:
		_label.text = "max fill +%.2f m above the basin rim (%.2f m) · capacity +%.0f kL" % [
				above, y, extra_l / 1000.0]


# -- Interactable ------------------------------------------------------------

func interact(_player: Node) -> void:
	_open_settings()


# -- GrabController relocatable-marker contract ------------------------------

func grab_distance_m() -> float:
	return GRAB_DISTANCE_M


func world_drag_begin() -> void:
	_dragging = true
	_drag_y = _max_y
	_apply_highlight(_hot)


## The crosshair ray's closest point to the VERTICAL line through the handle:
## the level follows the camera's pitch, never its yaw.
func world_drag_aim(camera: Camera3D) -> Variant:
	if camera == null:
		return null
	var vp := camera.get_viewport()
	if vp == null:
		return null
	var centre := vp.get_visible_rect().size * 0.5
	var o := camera.project_ray_origin(centre)
	var n := camera.project_ray_normal(centre).normalized()
	var p0 := Vector3(_centroid.x, _basin_rim, _centroid.y)
	var u := Vector3.UP
	# Closest points between ray (o + t n) and line (p0 + s u).
	var w := o - p0
	var a := n.dot(n)
	var b := n.dot(u)
	var c := u.dot(u)
	var d := n.dot(w)
	var e := u.dot(w)
	var den := a * c - b * b
	if absf(den) < 1e-6:
		return null
	var t := (b * e - c * d) / den
	var s := (a * e - b * d) / den
	if t <= 0.0:
		return null
	var y := clampf(_basin_rim + s, _basin_rim, _basin_rim + MAX_ABOVE_RIM_M)
	return Vector3(_centroid.x, y, _centroid.y)


func world_drag_preview(pos: Vector3) -> void:
	_drag_y = pos.y
	global_position = Vector3(_centroid.x, pos.y, _centroid.y)
	_update_readout(pos.y)


func world_drag_commit(pos: Vector3) -> void:
	_dragging = false
	_apply_highlight(_hot)
	var ok := false
	if _loader != null and _loader.has_method("set_pond_max_level"):
		ok = bool(_loader.call("set_pond_max_level", water_idx, pos.y))
	_last_commit = {"y": pos.y, "ok": ok}
	if not ok:
		sync_position()


func world_drag_cancel() -> void:
	_dragging = false
	_apply_highlight(_hot)
	sync_position()


func world_drag_click() -> void:
	_open_settings()


func debug_summary() -> Dictionary:
	return {"idx": water_idx, "tag": tag, "max_y": _max_y, "basin_rim": _basin_rim,
			"pos": global_position, "dragging": _dragging, "last_commit": _last_commit}


func _open_settings() -> void:
	if _loader != null and _loader.has_method("open_pond_editor"):
		_loader.call("open_pond_editor", water_idx)

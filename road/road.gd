@tool
extends Node3D

## Procedural gravel road that follows a Path3D curve.
##
## ── HOW TO USE ─────────────────────────────────────────────────────────────
##
##  1. Instance road.tscn into your scene.
##
##  2. Select the child "Path" node.  Godot shows orange diamond handles for
##     each waypoint.  The toolbar at the top of the 3D viewport has:
##       • Select-points mode  (click a handle to select / move it)
##       • Add-point mode      (click anywhere on the curve line to insert a
##                              new point; click on empty ground to append)
##       • Delete-point mode   (click a handle to remove it)
##     Use the "Add point" mode to extend the road, then switch back to
##     "Select" to drag individual handles into place.
##
##  3. Each selected waypoint also has two smaller "tilt/curve" handles
##     (the circular ends of the Bezier arms).  Drag those to control how
##     sharply the road curves at that point.  Alternatively, click the
##     "Smooth Handles" button below — it calculates natural curves for you
##     automatically.
##
##  4. If points end up below the terrain, use "Snap to Terrain" (bottom of
##     the Inspector) to raycast every waypoint down onto the physics surface.
##
##  5. For a flat road, use "Flatten to Average Y" to level all waypoints to
##     their average height in one click.
##
## ───────────────────────────────────────────────────────────────────────────

# ── Road Shape ──────────────────────────────────────────────────────────────

@export_group("Road Shape")

## Width of the road surface in metres.
@export var road_width: float = 6.0:
	set(v):
		road_width = maxf(v, 0.1)
		_build_mesh()

## Cross-section slices per metre of road length.  2–3 is plenty for gentle
## curves; raise to 5+ only for very tight bends.
@export var segments_per_meter: float = 2.0:
	set(v):
		segments_per_meter = clampf(v, 0.1, 20.0)
		_build_mesh()

## Small vertical lift above the terrain surface to prevent Z-fighting.
@export var y_offset: float = 0.05:
	set(v):
		y_offset = v
		_build_mesh()

# ── Road Material ────────────────────────────────────────────────────────────

@export_group("Road Material")

## Metres of road per UV tile repeat along the road length.
@export var uv_tile_length: float = 4.0:
	set(v):
		uv_tile_length = maxf(v, 0.01)
		_build_mesh()

## Material applied to the road surface.
## UV.x = 0→1 across width, UV.y tiles along the length.
@export var road_surface_material: Material:
	set(v):
		road_surface_material = v
		if _mesh_instance:
			_mesh_instance.material_override = road_surface_material

# ── Path Tools ───────────────────────────────────────────────────────────────

@export_group("Path Tools — Smooth Handles")

## How far each Bezier handle reaches as a fraction of the distance to the
## neighbouring waypoint.  0.25 → gentle curves; 0.5 → more swooping arcs.
@export_range(0.05, 0.6) var handle_tension: float = 0.28

## Click to auto-compute smooth Bezier handles for every waypoint using a
## Catmull-Rom formula.  Run this after placing all your waypoints.
@export var smooth_handles_now: bool = false:
	set(_v):
		_smooth_handles()

@export_group("Path Tools — Flatten Y")

## Click to compute the average Y of all waypoints and level every point to
## that height.  Good for roads that run across nearly-flat terrain.
@export var flatten_to_average_y_now: bool = false:
	set(_v):
		_flatten_to_average_y()

## Override Y — set this to a specific world height then click Apply.
@export var flatten_y_override: float = 0.0

## Click to move every waypoint to exactly flatten_y_override.
@export var apply_y_override_now: bool = false:
	set(_v):
		_apply_y_override()

@export_group("Path Tools — Terrain Snap")

## Physics collision mask used when raycasting downward to find the terrain.
## Bit 1 (value = 1) is the default layer; match whatever layer your terrain
## collision is on.
@export_flags_3d_physics var terrain_mask: int = 1

## Extra height added after snapping so the road sits on top of the surface.
@export var snap_lift: float = 0.1

## Click to shoot a ray straight down from each waypoint and move it onto the
## terrain surface.  Run "Smooth Handles" again afterwards if needed.
@export var snap_to_terrain_now: bool = false:
	set(_v):
		_snap_to_terrain()

# ── Debug ────────────────────────────────────────────────────────────────────

@export_group("Debug")

## Force a full mesh rebuild (useful if the curve was edited by another tool).
@export var rebuild_now: bool = false:
	set(_v):
		_build_mesh()

# ── Private state ─────────────────────────────────────────────────────────────

var _mesh_instance: MeshInstance3D
var _path: Path3D
var _curve_connected: bool = false


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _notification(what: int) -> void:
	# Rebuild whenever this node (re)enters the scene tree — covers both the
	# editor @tool pass and the in-game first frame.
	if what == NOTIFICATION_ENTER_TREE:
		# Defer so all children are guaranteed to be in the tree first.
		call_deferred("_deferred_init")


func _deferred_init() -> void:
	_path = get_node_or_null("Path")
	_mesh_instance = get_node_or_null("RoadMesh")
	_connect_curve_signal()
	_build_mesh()


func _ready() -> void:
	# _deferred_init already queued by _notification; call directly here as a
	# fallback in case the deferred call hasn't fired yet (e.g. editor hot-reload).
	if not _path or not _mesh_instance:
		_path = get_node_or_null("Path")
		_mesh_instance = get_node_or_null("RoadMesh")
		_connect_curve_signal()
	_build_mesh()


func _connect_curve_signal() -> void:
	if not _path:
		_path = get_node_or_null("Path")
	if _path and _path.curve and not _curve_connected:
		_path.curve.changed.connect(_build_mesh)
		_curve_connected = true


# ── Mesh generation ───────────────────────────────────────────────────────────

func _build_mesh() -> void:
	if not is_inside_tree():
		return

	if not _path:
		_path = get_node_or_null("Path")
	if not _mesh_instance:
		_mesh_instance = get_node_or_null("RoadMesh")
	if not _path or not _mesh_instance:
		return

	_connect_curve_signal()

	var curve: Curve3D = _path.curve
	if not curve:
		return

	var length: float = curve.get_baked_length()
	if length < 0.1:
		_mesh_instance.mesh = null
		return

	# ------------------------------------------------------------------
	# Sample positions along the baked curve, then derive tangents via
	# central differences — avoids the look_at() zero-vector crash.
	# ------------------------------------------------------------------
	var seg_count: int = max(2, int(ceil(length * segments_per_meter)))
	var sample_count: int = seg_count + 1
	var half_w: float = road_width * 0.5

	var positions: Array[Vector3] = []
	positions.resize(sample_count)
	for i in range(sample_count):
		var dist: float = (float(i) / float(seg_count)) * length
		positions[i] = curve.sample_baked(dist, true)

	var verts:   PackedVector3Array = []
	var norms:   PackedVector3Array = []
	var uvs:     PackedVector2Array = []
	var indices: PackedInt32Array   = []

	verts.resize(sample_count * 2)
	norms.resize(sample_count * 2)
	uvs.resize(sample_count * 2)

	var last_right: Vector3 = Vector3.RIGHT

	for i in range(sample_count):
		# Central-difference tangent.
		var tangent: Vector3
		if i == 0:
			tangent = positions[1] - positions[0]
		elif i == seg_count:
			tangent = positions[seg_count] - positions[seg_count - 1]
		else:
			tangent = positions[i + 1] - positions[i - 1]

		if tangent.length_squared() > 1e-8:
			# Flatten to XZ so the cross-section stays horizontal regardless
			# of slope, then derive the perpendicular right vector.
			var fwd := Vector3(tangent.x, 0.0, tangent.z)
			if fwd.length_squared() > 1e-8:
				last_right = fwd.normalized().cross(Vector3.UP).normalized()
			# else keep last_right from the previous iteration

		var vi: int = i * 2
		var centre: Vector3 = positions[i] + Vector3.UP * y_offset
		verts[vi]     = centre - last_right * half_w
		verts[vi + 1] = centre + last_right * half_w
		norms[vi]     = Vector3.UP
		norms[vi + 1] = Vector3.UP

		var uv_v: float = ((float(i) / float(seg_count)) * length) / uv_tile_length
		uvs[vi]     = Vector2(0.0, uv_v)
		uvs[vi + 1] = Vector2(1.0, uv_v)

	# Two triangles per quad segment.
	for i in range(seg_count):
		var b: int = i * 2
		indices.append(b);     indices.append(b + 2); indices.append(b + 1)
		indices.append(b + 1); indices.append(b + 2); indices.append(b + 3)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = arr_mesh

	if road_surface_material:
		_mesh_instance.material_override = road_surface_material


# ── Path tool helpers ─────────────────────────────────────────────────────────

## Auto-smooth: compute Catmull-Rom style handles for every waypoint.
## The handle length is scaled by handle_tension × distance to the neighbour.
func _smooth_handles() -> void:
	if not _path or not _path.curve:
		return
	var curve: Curve3D = _path.curve
	var n: int = curve.point_count
	if n < 2:
		return

	var pts: Array[Vector3] = []
	pts.resize(n)
	for i in range(n):
		pts[i] = curve.get_point_position(i)

	for i in range(n):
		var prev: Vector3 = pts[max(i - 1, 0)]
		var curr: Vector3 = pts[i]
		var next: Vector3 = pts[min(i + 1, n - 1)]

		# Catmull-Rom tangent direction, flattened to XZ for a road.
		var tangent: Vector3 = next - prev
		tangent.y = 0.0

		if tangent.length_squared() < 1e-8:
			curve.set_point_in(i, Vector3.ZERO)
			curve.set_point_out(i, Vector3.ZERO)
			continue

		# Scale handle by distance to the relevant neighbour × tension so
		# handles are proportionate regardless of waypoint spacing.
		var dist_out: float = curr.distance_to(next) * handle_tension
		var dist_in: float  = curr.distance_to(prev) * handle_tension
		var dir: Vector3    = tangent.normalized()

		curve.set_point_in(i,  -dir * (dist_in  if i > 0     else 0.0))
		curve.set_point_out(i,  dir * (dist_out if i < n - 1 else 0.0))

	_build_mesh()


## Move every waypoint to the average Y of all current waypoints, and zero
## out the Y component of all Bezier handles so the road stays flat.
func _flatten_to_average_y() -> void:
	if not _path or not _path.curve:
		return
	var curve: Curve3D = _path.curve
	var n: int = curve.point_count
	if n == 0:
		return

	var avg_y: float = 0.0
	for i in range(n):
		avg_y += curve.get_point_position(i).y
	avg_y /= float(n)

	flatten_y_override = avg_y   # mirror into the inspector field
	_set_all_points_to_y(avg_y)


## Move every waypoint to exactly flatten_y_override.
func _apply_y_override() -> void:
	if not _path or not _path.curve:
		return
	_set_all_points_to_y(flatten_y_override)


func _set_all_points_to_y(target_y: float) -> void:
	var curve: Curve3D = _path.curve
	for i in range(curve.point_count):
		var pos: Vector3 = curve.get_point_position(i)
		pos.y = target_y
		curve.set_point_position(i, pos)
		# Zero the Y of handles so they don't pull the road up/down.
		var h_in:  Vector3 = curve.get_point_in(i);  h_in.y  = 0.0
		var h_out: Vector3 = curve.get_point_out(i); h_out.y = 0.0
		curve.set_point_in(i,  h_in)
		curve.set_point_out(i, h_out)
	_build_mesh()


## Raycast each waypoint straight down and move it onto the terrain surface.
func _snap_to_terrain() -> void:
	if not _path or not _path.curve:
		return
	if not is_inside_tree():
		push_warning("RoadPath: snap_to_terrain requires the node to be in the scene tree.")
		return

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var curve: Curve3D = _path.curve
	var path_xform: Transform3D = _path.global_transform
	var path_xform_inv: Transform3D = path_xform.inverse()
	const RAY_UP: float   = 2000.0
	const RAY_DOWN: float = 2000.0

	for i in range(curve.point_count):
		var local_pos: Vector3  = curve.get_point_position(i)
		var world_pos: Vector3  = path_xform * local_pos
		var ray_from: Vector3   = world_pos + Vector3.UP * RAY_UP
		var ray_to: Vector3     = world_pos - Vector3.DOWN * RAY_DOWN

		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, terrain_mask)
		query.collide_with_areas = false

		var result: Dictionary = space.intersect_ray(query)
		if result.is_empty():
			continue

		var hit_world: Vector3 = result["position"] + Vector3.UP * snap_lift
		var hit_local: Vector3 = path_xform_inv * hit_world
		# Preserve the XZ curve position; only update Y.
		hit_local.x = local_pos.x
		hit_local.z = local_pos.z
		curve.set_point_position(i, hit_local)

		# Keep handles flat after the snap.
		var h_in:  Vector3 = curve.get_point_in(i);  h_in.y  = 0.0
		var h_out: Vector3 = curve.get_point_out(i); h_out.y = 0.0
		curve.set_point_in(i,  h_in)
		curve.set_point_out(i, h_out)

	_build_mesh()

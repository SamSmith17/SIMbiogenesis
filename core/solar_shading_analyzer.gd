extends Node
class_name SolarShadingAnalyzer

signal progress_updated(percent: float, text: String)
signal analysis_completed(heatmap: ImageTexture, rect: Rect2)

var _is_running := false
var _grid_size := 128
var _bounds_rect: Rect2
var _main: Node
var _clock: CelestialClock

var _test_points: PackedVector3Array
var _hits: PackedInt32Array

var _current_point_idx: int = 0
var _sun_dirs: Array[Vector3]
var _bounds: Rect2

var _temp_bodies: Array[RID] = []
var _temp_shapes: Array[Resource] = []

func _exit_tree() -> void:
	_is_running = false
	_cleanup_temp_colliders()

func is_running() -> bool:
	return _is_running

func start_analysis(main: Node, grid_res: int = 128) -> void:
	if _is_running:
		return
	_main = main
	_clock = _main.get("clock") as CelestialClock
	if not _clock:
		analysis_completed.emit(null, Rect2())
		return
		
	_grid_size = grid_res
	
	# 1. Determine bounds
	var center_x := 0.0
	var center_z := 0.0
	var radius := 200.0
	var soi = get_node_or_null("/root/SoiService")
	if soi and soi.get("_config"):
		center_x = soi._config.center_x
		center_z = soi._config.center_z
		radius = soi._config.radius_m
	
	var size := radius * 2.0
	_bounds_rect = Rect2(center_x - radius, center_z - radius, size, size)
	_bounds = _bounds_rect
	
	# 2. Precompute Sun Directions for the year (1 day/month, daylight hours)
	_sun_dirs.clear()
	
	_current_point_idx = 0
	_test_points = PackedVector3Array()
	_hits = PackedInt32Array()
	progress_updated.emit(0.0, "Preparing bounds and obstacles...")
	
	_create_temp_colliders()
	
	# Wait for physics engine to build the broadphase BVH for the new bodies
	await _main.get_tree().physics_frame
	await _main.get_tree().physics_frame
	
	var tc = CelestialClock.new()
	tc.latitude = _clock.latitude
	tc.longitude = _clock.longitude
	tc.auto_dst = _clock.auto_dst
	tc.manual_dst = _clock.manual_dst
	tc.year = _clock.year
	
	for month in range(1, 13):
		tc.month = month
		tc.day = 15
		for hour in range(6, 19): # Roughly daylight hours
			tc.day_time = float(hour)
			var sun_dir = tc.get_sun_direction()
			if sun_dir.y > 0: # Sun is above horizon
				_sun_dirs.append(sun_dir)
				
	_is_running = true
	set_process(true)

func _process(_delta: float) -> void:
	if not _is_running:
		set_process(false)
		return
		
	var world: World3D = _main.get_world_3d() if _main.is_inside_tree() else null
	if world == null:
		_finish_analysis(true)
		return
	var space = world.direct_space_state
	if not space:
		return
	
	# Initialization phase: Finding ground heights
	if _test_points.size() < _grid_size * _grid_size:
		var start_idx = _test_points.size()
		var start_x = _bounds_rect.position.x
		var start_z = _bounds_rect.position.y
		var step_x = _bounds_rect.size.x / float(_grid_size - 1)
		var step_z = _bounds_rect.size.y / float(_grid_size - 1)
		
		# Process in rows to simplify logic for "chunking" initialization
		var current_z = _test_points.size() / _grid_size
		var rows_per_frame = 8
		var end_z = mini(current_z + rows_per_frame, _grid_size)
		
		for z in range(current_z, end_z):
			var pz = start_z + z * step_z
			for x in range(_grid_size):
				var px = start_x + x * step_x
				
				var query = PhysicsRayQueryParameters3D.create(Vector3(px, 4000.0, pz), Vector3(px, -100.0, pz))
				query.collide_with_areas = false
				query.collide_with_bodies = true
				var hit = space.intersect_ray(query)
				if not hit.is_empty():
					_test_points.append(hit.position + Vector3(0, 0.1, 0))
				else:
					var gy = TerrainSurfaceQuery.ground_height_at(_main, px, pz)
					_test_points.append(Vector3(px, gy + 0.1, pz))
				_hits.append(0)
			
		var pct = float(_test_points.size()) / float(_grid_size * _grid_size) * 0.1 # First 10% is ground finding
		progress_updated.emit(pct, "Finding terrain: %d%%" % int(pct * 100))
		return

	# Raycasting phase
	var rays_per_frame = 400
	var end_idx = mini(_current_point_idx + rays_per_frame, _test_points.size())
	
	for i in range(_current_point_idx, end_idx):
		var p = _test_points[i]
		var lit_count = 0
		for dir in _sun_dirs:
			var query = PhysicsRayQueryParameters3D.create(p, p + dir * 4000.0)
			query.collide_with_areas = false
			query.collide_with_bodies = true
			query.hit_back_faces = true
			var hit = space.intersect_ray(query)
			if hit.is_empty():
				lit_count += 1
				
		_hits[i] = lit_count
		
	_current_point_idx = end_idx
	
	var pct = 0.1 + (float(_current_point_idx) / float(_test_points.size())) * 0.9
	progress_updated.emit(pct, "Analyzing shading: %d%%" % int(pct * 100))
	
	if _current_point_idx >= _test_points.size():
		_finish_analysis()
		
func _finish_analysis(failed: bool = false) -> void:
	_cleanup_temp_colliders()
	_is_running = false
	set_process(false)
	
	if failed:
		analysis_completed.emit(null, Rect2())
		return
	
	var total_sun = _sun_dirs.size()
	if total_sun == 0:
		total_sun = 1
	
	var img = Image.create(_grid_size, _grid_size, false, Image.FORMAT_RGBA8)
	for y in range(_grid_size):
		for x in range(_grid_size):
			var idx = y * _grid_size + x
			var lit = _hits[idx]
			var ratio = float(lit) / float(total_sun)
			var c = _color_for_ratio(ratio)
			
			# Add transparency mapping: highly shaded (0.0) = less opaque so terrain is visible
			c.a = 0.65
			img.set_pixel(x, y, c)
			
	var tex = ImageTexture.create_from_image(img)
	progress_updated.emit(1.0, "Complete!")
	analysis_completed.emit(tex, _bounds)

func _cleanup_temp_colliders() -> void:
	for body in _temp_bodies:
		PhysicsServer3D.free_rid(body)
	_temp_bodies.clear()
	_temp_shapes.clear()

func _create_temp_colliders() -> void:
	var space = _main.get_world_3d().space
	var terrain = _main.get_node_or_null("Terrain")
	if not terrain: return
	
	var b_root = terrain.get_node_or_null("Buildings")
	if b_root:
		_process_mesh_instances(b_root, space)
		
	var bc_root = terrain.get_node_or_null("BuildingsCustom")
	if bc_root:
		_process_mesh_instances(bc_root, space)
		
	for v_name in ["Vegetation", "AutoVegetation"]:
		var v_root = terrain.get_node_or_null(v_name)
		if v_root:
			_process_veg(v_root, space)

func _process_mesh_instances(node: Node, space: RID) -> void:
	if node is MeshInstance3D and node.mesh:
		var shape = node.mesh.create_trimesh_shape()
		if shape:
			var shape_rid = shape.get_rid()
			var body_rid = PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
			PhysicsServer3D.body_set_space(body_rid, space)
			PhysicsServer3D.body_add_shape(body_rid, shape_rid)
			PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, node.global_transform)
			_temp_bodies.append(body_rid)
			_temp_shapes.append(shape)
	for child in node.get_children():
		_process_mesh_instances(child, space)

func _process_veg(node: Node, space: RID) -> void:
	if node is MultiMeshInstance3D and node.multimesh:
		var n_lower = node.name.to_lower()
		if n_lower.contains("grass") or n_lower.contains("field") or n_lower.contains("lawn"):
			pass # Skip grass and fields
		else:
			var mm = node.multimesh
			var shape = SphereShape3D.new()
			shape.radius = 3.0 # Approximate radius for a tree canopy
			var shape_rid = shape.get_rid()
			_temp_shapes.append(shape)
			
			var body_rid = PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
			PhysicsServer3D.body_set_space(body_rid, space)
			var gt = node.global_transform
			for i in range(mm.instance_count):
				var t = mm.get_instance_transform(i)
				t.origin += t.basis.y * 3.5 # Move sphere up into the canopy
				PhysicsServer3D.body_add_shape(body_rid, shape_rid, t)
			PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, gt)
			_temp_bodies.append(body_rid)
			
	for child in node.get_children():
		_process_veg(child, space)

func _color_for_ratio(r: float) -> Color:
	if r < 0.25:
		return Color(0, 0, 1).lerp(Color(0, 1, 1), r * 4.0)
	elif r < 0.5:
		return Color(0, 1, 1).lerp(Color(0, 1, 0), (r - 0.25) * 4.0)
	elif r < 0.75:
		return Color(0, 1, 0).lerp(Color(1, 1, 0), (r - 0.5) * 4.0)
	else:
		return Color(1, 1, 0).lerp(Color(1, 0, 0), (r - 0.75) * 4.0)

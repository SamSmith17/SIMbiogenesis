extends CrisisEvent
class_name FireEvent

## Fire crisis event - starts random fires on visible geometry

## All active fire nodes
var active_fires : Array[FireNode] = []

## All structure nodes containing meshes
var structure_nodes : Array[Node3D] = []

## Cluster manager for efficient fire rendering
var cluster_manager : FireClusterManager = null

## Time since event started (in sim hours)
var elapsed_hours : float = 0.0

## Event duration limit (2 hours simulation time)
const MAX_DURATION_HOURS : float = 2.0

## Threshold for creating cluster manager
const CLUSTER_THRESHOLD : int = 25

func _init() -> void:
	event_name = "Fire"
	severity = EventSeverity.MEDIUM
	event_id = "fire_%d" % Time.get_ticks_msec()

func can_trigger(context: Dictionary) -> bool:
	if state != EventState.PENDING:
		return false
	
	var tree : SceneTree = context.get("scene_tree")
	if tree == null:
		return false
	
	# Find all burnable structures
	var structures := _find_all_structures(tree.current_scene, context)
	if structures.is_empty():
		return false
	
	# Count total meshes
	var total_meshes := 0
	for structure in structures:
		var meshes := _find_structure_meshes(structure)
		total_meshes += meshes.size()
	
	return total_meshes > 0

func start_event(context: Dictionary) -> bool:
	if not super.start_event(context):
		return false
	
	var tree : SceneTree = context.get("scene_tree")
	if tree == null:
		return false
	
	# Find all structures
	structure_nodes = _find_all_structures(tree.current_scene, context)
	if structure_nodes.is_empty():
		return false
	
	# Collect ALL meshes from all structures
	var all_meshes : Array[MeshInstance3D] = []
	for structure in structure_nodes:
		var meshes := _find_structure_meshes(structure)
		all_meshes.append_array(meshes)
	
	if all_meshes.is_empty():
		return false
	
	# Pick ignition mesh.
	# Debug/manual fire can request "near player" so the fire is easy to see.
	var target_mesh : MeshInstance3D = null
	var prefer_near_player : bool = bool( context.get( "prefer_near_player", false ) )
	if prefer_near_player :
		var player_node : Node3D = context.get( "player", null ) as Node3D
		if player_node != null and is_instance_valid( player_node ) :
			var best_dist_sq := INF
			for m in all_meshes :
				if m == null or not is_instance_valid( m ) :
					continue
				var d_sq := m.global_position.distance_squared_to( player_node.global_position )
				if d_sq < best_dist_sq :
					best_dist_sq = d_sq
					target_mesh = m
	if target_mesh == null :
		target_mesh = all_meshes[randi() % all_meshes.size()]
	
	# Spawn fire on this mesh
	var fire := _spawn_fire_on_mesh(target_mesh, tree)
	if fire == null:
		return false
	
	return true

## Find all structures that can have fires (LinkageLab, Mars Aerial, etc)
func _find_all_structures(root: Node, context: Dictionary = {}) -> Array[Node3D]:
	var result : Array[Node3D] = []
	_collect_context_structures(root, context, result)
	_collect_structures(root, result)
	return result

func _collect_context_structures(root: Node, context: Dictionary, result: Array[Node3D]) -> void:
	if root == null:
		return
	
	# Preferred direct node reference (single)
	var preferred_single: Variant = context.get("structure", null)
	if preferred_single != null and preferred_single is Node3D:
		_append_unique_structure(preferred_single as Node3D, result)
	
	# Preferred direct node references (list)
	var preferred_many: Variant = context.get("burnable_roots", [])
	if preferred_many is Array:
		for entry in preferred_many:
			if entry != null and entry is Node3D:
				_append_unique_structure(entry as Node3D, result)
	
	# Preferred node paths relative to current scene root
	var preferred_paths: Variant = context.get("burnable_root_paths", PackedStringArray())
	if preferred_paths is PackedStringArray:
		for path_str in preferred_paths:
			var n: Node = root.get_node_or_null(NodePath(path_str))
			if n != null and n is Node3D:
				_append_unique_structure(n as Node3D, result)
	elif preferred_paths is Array:
		for path_any in preferred_paths:
			var p: String = str(path_any)
			var n2: Node = root.get_node_or_null(NodePath(p))
			if n2 != null and n2 is Node3D:
				_append_unique_structure(n2 as Node3D, result)
	
	# Explicit fallback for the unstable soak scene.
	var soak_camps := root.get_node_or_null("Soak Site Camps2")
	if soak_camps != null and soak_camps is Node3D:
		_append_unique_structure(soak_camps as Node3D, result)

func _append_unique_structure(node: Node3D, result: Array[Node3D]) -> void:
	for existing in result:
		if existing == node:
			return
	result.append(node)

func _collect_structures(node: Node, result: Array[Node3D]) -> void:
	if node == null:
		return
	
	var name_lower := node.name.to_lower()
	
	# Check for known structure names
	var is_structure := false
	if "linkagelab" in name_lower or "linkage_lab" in name_lower:
		is_structure = true
	elif "mars" in name_lower and "aerial" in name_lower:
		is_structure = true
	elif "located" in name_lower:
		is_structure = true
	# "Soak Site Camps2" (and variants) — burnable camp structures in the unstable scene.
	# Matched specifically by "soak" + "camp" so we don't accidentally pick up Soak terrain.
	elif "soak" in name_lower and "camp" in name_lower:
		is_structure = true
	
	if is_structure and node is Node3D:
		_append_unique_structure(node as Node3D, result)
	
	# Check children
	for child in node.get_children():
		_collect_structures(child, result)

func update_event(delta: float, context: Dictionary) -> void:
	super.update_event(delta, context)
	
	if state != EventState.ACTIVE:
		return
	
	# Get time scale
	var time_scale := context.get("time_scale", 1.0) as float
	elapsed_hours += delta * time_scale
	
	# Clean up invalid fires
	var valid_fires : Array[FireNode] = []
	for fire in active_fires:
		if is_instance_valid(fire):
			valid_fires.append(fire)
	active_fires = valid_fires
	
	# Manage cluster manager based on fire count
	_manage_cluster_manager(context)
	
	# Check if all fires extinguished (success!)
	if active_fires.is_empty():
		resolve_event()
		return
	
	# Check for timeout (failure)
	if elapsed_hours >= MAX_DURATION_HOURS:
		fail_event()
		return

func _manage_cluster_manager(context: Dictionary) -> void:
	var tree : SceneTree = context.get("scene_tree")
	if tree == null:
		return
	
	var fire_count := active_fires.size()
	
	# Create cluster manager if we have enough fires
	if fire_count >= CLUSTER_THRESHOLD and cluster_manager == null:
		cluster_manager = FireClusterManager.new()
		cluster_manager.name = "FireClusterManager"
		tree.current_scene.add_child(cluster_manager)
	
	# Remove cluster manager if fires reduced
	if fire_count < CLUSTER_THRESHOLD and cluster_manager != null:
		cluster_manager.queue_free()
		cluster_manager = null

func cleanup() -> void:
	for fire in active_fires:
		if is_instance_valid(fire):
			fire.queue_free()
	active_fires.clear()
	structure_nodes.clear()
	
	# Clean up cluster manager
	if cluster_manager != null:
		cluster_manager.queue_free()
		cluster_manager = null

func _find_structure_meshes(structure: Node3D) -> Array[MeshInstance3D]:
	var result : Array[MeshInstance3D] = []
	_collect_meshes(structure, result)
	
	# Some imported FBX camp scenes (e.g. Soak Site Camps2) can have mesh naming/
	# sizing that the strict filter misses. Fall back to permissive collection so
	# manual fire trigger (F) always has valid burnable targets there.
	if result.is_empty() and _is_likely_soak_camp_structure(structure):
		_collect_meshes_permissive(structure, result)
	
	return result

func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	# Skip invisible nodes entirely (including their children)
	if node is Node3D:
		var node3d := node as Node3D
		if not node3d.visible:
			return
	
	if node is MeshInstance3D:
		var mesh := node as MeshInstance3D
		
		# Skip invisible meshes
		if not mesh.is_visible_in_tree():
			return
		
		var name_lower := mesh.name.to_lower()
		
		# Skip terrain/ground meshes and player equipment.
		# Note: "plane" was previously in this list but stripped tent/panel meshes
		# from FBX imports that legitimately use names like "Plane001". The AABB
		# size filter below handles tiny placeholder planes well enough.
		var skip_keywords := ["terrain", "ground", "floor", "temporary", "bulb", "wire", "light", "halo", "string", "extinguisher", "player", "tool", "camera"]
		var should_skip := false
		for keyword in skip_keywords:
			if keyword in name_lower:
				should_skip = true
				break
		
		if not should_skip:
			# Make sure mesh has some size (filter out tiny objects)
			var aabb := mesh.get_aabb()
			if aabb.size.length() > 0.5:  # Slightly larger minimum size
				result.append(mesh)
	
	for child in node.get_children():
		_collect_meshes(child, result)

func _is_likely_soak_camp_structure(node: Node) -> bool:
	if node == null:
		return false
	var name_lower := node.name.to_lower()
	return "soak" in name_lower and "camp" in name_lower

func _collect_meshes_permissive(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		var mesh := node as MeshInstance3D
		if mesh.mesh != null:
			var aabb := mesh.get_aabb()
			if aabb.size.length() > 0.01:
				result.append(mesh)
	
	for child in node.get_children():
		_collect_meshes_permissive(child, result)

func _spawn_fire_on_mesh(mesh: MeshInstance3D, tree: SceneTree) -> FireNode:
	if mesh == null:
		return null
	if mesh.has_meta("fire_active") and bool(mesh.get_meta("fire_active")):
		return null
	mesh.set_meta("fire_active", true)
	
	# Create fire node
	var fire := FireNode.new()
	fire.name = "Fire_%s" % mesh.name
	fire.target_mesh = mesh
	
	# Calculate spawn position near upper portion of mesh.
	# Center-only spawn can appear hidden inside larger models.
	var aabb := mesh.get_aabb()
	var local_spawn := aabb.get_center()
	local_spawn.y = aabb.position.y + aabb.size.y * 0.72
	var center := mesh.to_global( local_spawn )
	
	# Add to scene
	if tree.current_scene == null:
		mesh.set_meta("fire_active", false)
		return null
	
	tree.current_scene.add_child(fire)
	fire.global_position = center
	
	# Connect signals
	fire.fire_extinguished.connect(_on_fire_extinguished.bind(fire))
	fire.fire_spread.connect(_on_fire_spread)
	fire.mesh_destroyed.connect(_on_mesh_destroyed)
	
	active_fires.append(fire)
	
	return fire

func _on_fire_extinguished(fire: FireNode) -> void:
	var idx := active_fires.find(fire)
	if idx >= 0:
		active_fires.remove_at(idx)
	else:
		pass
	
	# Check immediately if all fires are out
	if active_fires.is_empty():
		resolve_event()

func _on_fire_spread(target_mesh: MeshInstance3D) -> void:
	var tree := target_mesh.get_tree()
	if tree == null:
		return
	
	var new_fire := _spawn_fire_on_mesh(target_mesh, tree)
	if new_fire != null:
		pass

func _on_mesh_destroyed(mesh: MeshInstance3D) -> void:
	pass

func get_status_description() -> String:
	if state == EventState.ACTIVE:
		var fire_count := active_fires.size()
		var biggest_fire : FireNode = null
		for fire in active_fires:
			if is_instance_valid(fire):
				if biggest_fire == null or fire.intensity > biggest_fire.intensity:
					biggest_fire = fire
		
		var status := "🔥 FIRE: %d active" % fire_count
		if biggest_fire != null:
			status += " - %s (%.0f%%)" % [biggest_fire.get_state_text(), biggest_fire.intensity]
			var time_left := FireNode.DESTROY_TIME_HOURS - biggest_fire.fire_time_hours
			if time_left > 0:
				var mins := int(time_left * 60)
				status += " - %d min to destruction" % mins
		
		return status
	
	return super.get_status_description()

## Pause the fire event (called when time is sped up)
## Hides all fire effects to save GPU but keeps state
func pause_event() -> void:
	for fire in active_fires:
		if is_instance_valid(fire):
			fire.pause_fire()
	# Also pause cluster manager if present
	if cluster_manager != null and is_instance_valid(cluster_manager):
		cluster_manager.visible = false

## Resume the fire event (called when back to realtime)
func resume_event() -> void:
	for fire in active_fires:
		if is_instance_valid(fire):
			fire.resume_fire()
	# Resume cluster manager
	if cluster_manager != null and is_instance_valid(cluster_manager):
		cluster_manager.visible = true
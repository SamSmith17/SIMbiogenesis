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

	var scope := _resolve_burn_scope(tree.current_scene, context)
	if scope != null:
		var meshes := _find_structure_meshes(scope)
		for m in meshes:
			if m != null and not FireNode._is_forbidden_burn_target(m):
				return true
		return false

	if bool(context.get("restrict_to_structure", false)):
		return false

	var structures := _find_all_structures(tree.current_scene, context)
	if structures.is_empty():
		return false
	for structure in structures:
		if not _find_structure_meshes(structure).is_empty():
			return true
	return false

func start_event(context: Dictionary) -> bool:
	if not super.start_event(context):
		return false

	var tree : SceneTree = context.get("scene_tree")
	if tree == null:
		return false

	# Lock to ONE selected structure (focused / nearest burnable prop). Never
	# scatter across the whole SoI / player / drone.
	var scope := _resolve_burn_scope(tree.current_scene, context)
	if scope == null:
		if bool(context.get("restrict_to_structure", false)):
			return false
		structure_nodes = _find_all_structures(tree.current_scene, context)
		if structure_nodes.is_empty():
			return false
		scope = structure_nodes[0]
	structure_nodes = [scope]

	var all_meshes := _find_structure_meshes(scope)
	# Filter forbidden (player/drone/SoI) even if they somehow sit under a root.
	var meshes: Array[MeshInstance3D] = []
	for m in all_meshes:
		if m != null and is_instance_valid(m) and not FireNode._is_forbidden_burn_target(m):
			meshes.append(m)
	if meshes.is_empty():
		return false

	var target_mesh := _pick_ignition_mesh(meshes, context)
	if target_mesh == null:
		return false

	var fire := _spawn_fire_on_mesh(target_mesh, tree, scope)
	return fire != null


## Prefer focused / context structure; else nearest burnable PlacedProp to player.
func _resolve_burn_scope(root: Node, context: Dictionary) -> Node3D:
	var preferred: Variant = context.get("structure", null)
	if preferred != null and preferred is Node3D and is_instance_valid(preferred):
		return preferred as Node3D
	var roots: Variant = context.get("burnable_roots", [])
	if roots is Array and (roots as Array).size() == 1:
		var only = (roots as Array)[0]
		if only is Node3D and is_instance_valid(only):
			return only as Node3D
	# Nearest burnable PlacedProp to the player.
	var player_node: Node3D = context.get("player", null) as Node3D
	if player_node == null or root == null:
		return null
	var best: Node3D = null
	var best_d := INF
	for node in root.find_children("*", "PlacedProp", true, false):
		var prop := node as PlacedProp
		if prop == null or not prop.burnable:
			continue
		var d := prop.global_position.distance_squared_to(player_node.global_position)
		if d < best_d:
			best_d = d
			best = prop
	return best


## Bottom-up ignition: lowest mesh near the player (Man catches from the feet).
func _pick_ignition_mesh(meshes: Array[MeshInstance3D], context: Dictionary) -> MeshInstance3D:
	if meshes.is_empty():
		return null
	var player_node: Node3D = context.get("player", null) as Node3D
	var prefer_bottom := bool(context.get("prefer_bottom", true))
	if prefer_bottom:
		var ranked: Array[Dictionary] = []
		for m in meshes:
			var aabb := FireNode._mesh_world_aabb(m)
			var bottom := aabb.position.y
			var dist := 0.0
			if player_node != null:
				dist = aabb.get_center().distance_to(player_node.global_position)
			ranked.append({"mesh": m, "bottom": bottom, "dist": dist})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			# Prefer near player among the lower third of the structure.
			return float(a["bottom"]) < float(b["bottom"])
		)
		# Among the lowest ~40% of pieces, pick the one closest to the player.
		var n_low := maxi(1, int(ceil(ranked.size() * 0.4)))
		var best: MeshInstance3D = ranked[0]["mesh"]
		var best_d := INF
		for i in n_low:
			var d: float = ranked[i]["dist"]
			if d < best_d:
				best_d = d
				best = ranked[i]["mesh"]
		return best
	# Legacy: nearest origin to player.
	if player_node != null and bool(context.get("prefer_near_player", false)):
		var nearest: MeshInstance3D = null
		var best_dsq := INF
		for m in meshes:
			var dsq := m.global_position.distance_squared_to(player_node.global_position)
			if dsq < best_dsq:
				best_dsq = dsq
				nearest = m
		if nearest != null:
			return nearest
	return meshes[randi() % meshes.size()]


## Find all structures that can have fires (LinkageLab, Mars Aerial, etc)
func _find_all_structures(root: Node, context: Dictionary = {}) -> Array[Node3D]:
	var result : Array[Node3D] = []
	# When context locks to one structure, don't scan the whole world.
	if bool(context.get("restrict_to_structure", false)):
		var scope := _resolve_burn_scope(root, context)
		if scope != null:
			result.append(scope)
			return result
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

	# User-placed props marked burnable in the place-options panel.
	_collect_burnable_placed_props(root, result)


func _collect_burnable_placed_props(root: Node, result: Array[Node3D]) -> void:
	if root == null:
		return
	var terrain := root.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var placed_root := terrain.get_node_or_null("PlacedProps")
	if placed_root == null:
		return
	for child in placed_root.get_children():
		if child is PlacedProp and (child as PlacedProp).burnable:
			_append_unique_structure(child as Node3D, result)

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
		
		if not should_skip and not FireNode._is_forbidden_burn_target(mesh):
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

func _spawn_fire_on_mesh(mesh: MeshInstance3D, tree: SceneTree, scope: Node = null) -> FireNode:
	if mesh == null:
		return null
	if FireNode._is_forbidden_burn_target(mesh):
		return null
	if mesh.has_meta("fire_active") and bool(mesh.get_meta("fire_active")):
		return null
	# Prefer absorbing into an existing fire on the same structure (perf).
	if scope == null:
		scope = FireNode._structure_root_of(mesh)
	for existing in active_fires:
		if existing != null and is_instance_valid(existing) and existing.burn_scope == scope:
			existing.absorb_mesh(mesh)
			return existing

	if active_fires.size() >= FireNode.MAX_SCENE_FIRE_NODES:
		# Grow the nearest existing fire instead of spawning another particle system.
		var best: FireNode = null
		var best_d := INF
		for existing in active_fires:
			if existing == null or not is_instance_valid(existing):
				continue
			var d := existing.global_position.distance_squared_to(mesh.global_position)
			if d < best_d:
				best_d = d
				best = existing
		if best != null:
			best.absorb_mesh(mesh)
			return best

	mesh.set_meta("fire_active", true)
	var fire := FireNode.new()
	fire.name = "Fire_%s" % mesh.name
	fire.target_mesh = mesh
	fire.burn_scope = scope if scope != null else FireNode._structure_root_of(mesh)
	fire.intensity = 16.0
	fire.growth_tier = 0

	# Start at the BOTTOM of the mesh so tall props (Man) burn upward.
	var spawn := FireNode.ignition_point_on_mesh_bottom(mesh)

	if tree.current_scene == null:
		mesh.set_meta("fire_active", false)
		return null

	tree.current_scene.add_child(fire)
	fire.global_position = spawn

	fire.fire_extinguished.connect(_on_fire_extinguished.bind(fire))
	fire.fire_spread.connect(_on_fire_spread)
	fire.mesh_destroyed.connect(_on_mesh_destroyed)

	active_fires.append(fire)
	return fire


func _on_fire_extinguished(fire: FireNode) -> void:
	var idx := active_fires.find(fire)
	if idx >= 0:
		active_fires.remove_at(idx)
	if active_fires.is_empty():
		resolve_event()


func _on_fire_spread(target_mesh: MeshInstance3D) -> void:
	# Spread is absorbed into the growing FireNode — do NOT spawn more particle systems.
	# (absorb_mesh already ran inside FireNode._try_spread.)
	if target_mesh == null:
		return
	# Safety: if a mesh somehow wasn't absorbed, fold into the matching scope fire.
	for fire in active_fires:
		if fire == null or not is_instance_valid(fire):
			continue
		if fire.burn_scope != null and FireNode._is_under(fire.burn_scope, target_mesh):
			if target_mesh not in fire.burning_meshes:
				fire.absorb_mesh(target_mesh)
			return


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

		var status := "🔥 FIRE: %d node(s)" % fire_count
		if biggest_fire != null:
			status += " — %s · tier %d · %d pieces" % [
				biggest_fire.get_state_text(),
				biggest_fire.growth_tier,
				biggest_fire.burning_meshes.size(),
			]
			var time_left := FireNode.DESTROY_TIME_HOURS - biggest_fire.fire_time_hours
			if time_left > 0:
				status += " — %d min left" % int(time_left * 60)
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
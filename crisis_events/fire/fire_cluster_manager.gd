extends Node3D
class_name FireClusterManager

## Manages fire visuals by clustering nearby fires
## Each cluster gets ONE combined particle system (flame→smoke) + ONE bright light
## This caps particle systems while keeping the realistic look

const CLUSTER_RADIUS : float = 18.0
const MAX_CLUSTERS : int = 25
const UPDATE_INTERVAL : float = 0.25

class FireCluster:
	var center : Vector3 = Vector3.ZERO
	var fires : Array[FireNode] = []
	var total_intensity : float = 0.0
	var combined_particles : GPUParticles3D = null  # Single flame→smoke system
	var light : OmniLight3D = null
	var visual_node : Node3D = null

var clusters : Array[FireCluster] = []
var _update_timer : float = 0.0
var _flicker_time : float = 0.0

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	_flicker_time += delta
	_update_timer += delta
	
	if _update_timer >= UPDATE_INTERVAL:
		_update_timer = 0.0
		_rebuild_clusters()
	
	_update_cluster_visuals(delta)

func _rebuild_clusters() -> void:
	var tree := get_tree()
	if tree == null:
		return
	
	var all_fires := tree.get_nodes_in_group("fire_nodes")
	if all_fires.is_empty():
		_clear_all_clusters()
		return
	
	var valid_fires : Array[FireNode] = []
	for fire in all_fires:
		if fire is FireNode and is_instance_valid(fire):
			valid_fires.append(fire as FireNode)
	
	if valid_fires.is_empty():
		_clear_all_clusters()
		return
	
	# Cluster by proximity
	var assigned : Array[bool] = []
	assigned.resize(valid_fires.size())
	assigned.fill(false)
	
	var new_cluster_data : Array[Dictionary] = []
	
	for i in range(valid_fires.size()):
		if assigned[i]:
			continue
		
		var cluster_fires : Array[FireNode] = [valid_fires[i]]
		var cluster_center := valid_fires[i].global_position
		assigned[i] = true
		
		for j in range(i + 1, valid_fires.size()):
			if assigned[j]:
				continue
			
			if valid_fires[j].global_position.distance_to(cluster_center) <= CLUSTER_RADIUS:
				cluster_fires.append(valid_fires[j])
				assigned[j] = true
				cluster_center = _calculate_center(cluster_fires)
		
		new_cluster_data.append({
			"fires": cluster_fires,
			"center": cluster_center
		})
		
		if new_cluster_data.size() >= MAX_CLUSTERS:
			for k in range(valid_fires.size()):
				if not assigned[k]:
					var nearest := _find_nearest_cluster(valid_fires[k].global_position, new_cluster_data)
					if nearest >= 0:
						new_cluster_data[nearest]["fires"].append(valid_fires[k])
						assigned[k] = true
			break
	
	_sync_clusters_to_data(new_cluster_data)

func _calculate_center(fires: Array[FireNode]) -> Vector3:
	if fires.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for fire in fires:
		sum += fire.global_position
	return sum / fires.size()

func _find_nearest_cluster(pos: Vector3, cluster_data: Array[Dictionary]) -> int:
	var nearest := -1
	var nearest_dist := INF
	for i in range(cluster_data.size()):
		var dist := pos.distance_to(cluster_data[i]["center"])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = i
	return nearest

func _sync_clusters_to_data(new_data: Array[Dictionary]) -> void:
	var needed := new_data.size()
	
	while clusters.size() > needed:
		var cluster : FireCluster = clusters.pop_back() as FireCluster
		if cluster != null and cluster.visual_node != null:
			cluster.visual_node.queue_free()
	
	while clusters.size() < needed:
		var cluster := FireCluster.new()
		cluster.visual_node = _create_cluster_visual()
		add_child(cluster.visual_node)
		clusters.append(cluster)
	
	for i in range(needed):
		clusters[i].fires = new_data[i]["fires"]
		clusters[i].center = new_data[i]["center"]

func _create_cluster_visual() -> Node3D:
	var node := Node3D.new()
	
	# ===== COMBINED FLAME→SMOKE PARTICLE SYSTEM =====
	# One system that starts as bright flames and fades to dark smoke as it rises
	var particles := GPUParticles3D.new()
	particles.name = "FlameSmoke"
	particles.amount = 60  # Moderate - shared across cluster
	particles.lifetime = 4.0  # Long enough to rise as smoke
	particles.emitting = true
	particles.fixed_fps = 20
	particles.visibility_aabb = AABB(Vector3(-25, -5, -25), Vector3(50, 100, 50))
	
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 3.0  # Wide emission for cluster
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 20.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 7.0
	mat.gravity = Vector3(0, 2.5, 0)  # Rise up
	mat.scale_min = 0.4
	mat.scale_max = 1.2
	mat.damping_min = 0.3
	mat.damping_max = 0.8
	
	# Scale increases as particles rise (smoke expands)
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.5))   # Small at start (flame)
	scale_curve.add_point(Vector2(0.3, 0.8))   # Growing
	scale_curve.add_point(Vector2(0.6, 1.5))   # Smoke size
	scale_curve.add_point(Vector2(1.0, 2.5))   # Large smoke puff
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	mat.scale_curve = scale_tex
	
	# KEY: Color gradient from WHITE-YELLOW → YELLOW → ORANGE → RED → GRAY SMOKE
	var color_grad := Gradient.new()
	color_grad.set_color(0, Color(1.0, 1.0, 0.85, 1.0))      # White-yellow (hottest)
	color_grad.add_point(0.1, Color(1.0, 0.95, 0.5, 1.0))    # Bright yellow
	color_grad.add_point(0.22, Color(1.0, 0.75, 0.2, 0.95))  # Golden yellow
	color_grad.add_point(0.35, Color(1.0, 0.5, 0.1, 0.9))    # Orange
	color_grad.add_point(0.5, Color(0.95, 0.25, 0.05, 0.8))  # Red
	color_grad.add_point(0.65, Color(0.5, 0.15, 0.08, 0.65)) # Dark ember
	color_grad.add_point(0.8, Color(0.3, 0.27, 0.24, 0.5))   # Gray smoke
	color_grad.set_color(1, Color(0.25, 0.23, 0.2, 0.0))     # Fade out
	var color_tex := GradientTexture1D.new()
	color_tex.gradient = color_grad
	mat.color_ramp = color_tex
	
	particles.process_material = mat

	# Soft round billboards (not low-poly spheres) — readable at distance, cheap.
	particles.draw_pass_1 = FireVfx.make_billboard_quad(
		Vector2(1.0, 1.4), true, Color(1.0, 0.55, 0.15), 2.2)

	node.add_child(particles)

	# Rising ember sparkles for the cluster centre.
	var embers := GPUParticles3D.new()
	embers.name = "Embers"
	embers.amount = 18
	embers.lifetime = 3.0
	embers.emitting = true
	embers.fixed_fps = 18
	embers.visibility_aabb = AABB(Vector3(-20, -2, -20), Vector3(40, 60, 40))
	var emat := ParticleProcessMaterial.new()
	emat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	emat.emission_sphere_radius = 2.5
	emat.direction = Vector3(0, 1, 0)
	emat.spread = 25.0
	emat.initial_velocity_min = 1.5
	emat.initial_velocity_max = 4.0
	emat.gravity = Vector3(0, 2.5, 0)
	emat.scale_min = 0.4
	emat.scale_max = 1.1
	var egrad := Gradient.new()
	egrad.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	egrad.colors = PackedColorArray([
		Color(1.0, 0.7, 0.2, 1.0),
		Color(1.0, 0.2, 0.05, 0.9),
		Color(0.4, 0.05, 0.0, 0.0),
	])
	var etex := GradientTexture1D.new()
	etex.gradient = egrad
	emat.color_ramp = etex
	embers.process_material = emat
	embers.draw_pass_1 = FireVfx.make_ember_quad()
	node.add_child(embers)

	# ===== BRIGHT FLICKERING LIGHT - Critical for visibility! =====
	var light := OmniLight3D.new()
	light.name = "FireLight"
	light.light_color = Color(1.0, 0.5, 0.15)
	light.light_energy = 12.0
	light.omni_range = 36.0
	light.omni_attenuation = 1.0
	light.shadow_enabled = false
	light.position = Vector3(0, 2, 0)
	node.add_child(light)

	return node

func _update_cluster_visuals(_delta: float) -> void:
	for cluster in clusters:
		if cluster.visual_node == null:
			continue
		
		cluster.total_intensity = 0.0
		var total_light_energy := 0.0  # Sum of all individual fire lights
		var valid_count := 0
		for fire in cluster.fires:
			if is_instance_valid(fire):
				cluster.total_intensity += fire.intensity
				# Estimate what the individual fire's light energy would be
				# Based on fire_node.gd light scaling: 8-18 energy based on intensity
				var fire_visual_factor := clampf(fire.intensity / 100.0, 0.0, 2.0)
				total_light_energy += lerpf(8.0, 18.0, fire_visual_factor)
				valid_count += 1
		
		if valid_count == 0:
			cluster.visual_node.visible = false
			continue
		
		cluster.visual_node.visible = true
		
		# Update position to cluster center
		var new_center := Vector3.ZERO
		for fire in cluster.fires:
			if is_instance_valid(fire):
				new_center += fire.global_position
		new_center /= valid_count
		cluster.center = new_center
		cluster.visual_node.global_position = new_center
		
		# Scale factors based on cluster size
		var avg_intensity := cluster.total_intensity / valid_count
		var intensity_factor := clampf(avg_intensity / 80.0, 0.5, 2.0)
		var count_factor := clampf(sqrt(float(valid_count)) / 3.0, 0.6, 2.5)
		var combined := intensity_factor * count_factor
		
		# Update particles
		var particles := cluster.visual_node.get_node_or_null("FlameSmoke") as GPUParticles3D
		if particles != null:
			# Scale particle count and emission radius with cluster size
			particles.amount = int(clampf(30 + valid_count * 1.5, 30, 80))
			
			var mat := particles.process_material as ParticleProcessMaterial
			if mat != null:
				mat.emission_sphere_radius = 2.0 + combined * 2.5
				mat.initial_velocity_max = 5.0 + combined * 3.0
				mat.scale_max = 1.0 + combined * 0.8
		
		# Update light - MATCH the total brightness of all individual fires!
		# This prevents dimming when fires transition to cluster management
		var light := cluster.visual_node.get_node_or_null("FireLight") as OmniLight3D
		if light != null:
			# Multi-frequency flicker for realistic fire
			var f1 := sin(_flicker_time * 6.0) * 0.2
			var f2 := sin(_flicker_time * 10.0) * 0.12
			var f3 := sin(_flicker_time * 15.0) * 0.08
			var flicker := 1.0 + f1 + f2 + f3
			
			# Use the TOTAL light energy from all fires, not a fixed formula
			# This ensures no dimming when transitioning to cluster mode
			# Cap it reasonably to avoid extreme brightness
			var target_energy := clampf(total_light_energy * 0.7, 15.0, 150.0)
			light.light_energy = target_energy * flicker
			
			# Range scales with number of fires
			light.omni_range = clampf(25.0 + valid_count * 2.0, 30.0, 100.0)
			
			# Color shifts slightly with flicker
			var color_shift := (sin(_flicker_time * 8.0) + 1.0) * 0.1
			light.light_color = Color(1.0, 0.45 + color_shift, 0.1 + color_shift * 0.5)

func _clear_all_clusters() -> void:
	for cluster in clusters:
		if cluster.visual_node != null:
			cluster.visual_node.queue_free()
	clusters.clear()

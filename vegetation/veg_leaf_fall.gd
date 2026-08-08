class_name VegLeafFall
extends Node3D

## Falling-leaf particles for the autumn drop (veg overhaul Phase 6).
##
## The canopy shaders already thin and recolour foliage over the season; what
## was missing is the leaves going somewhere. This hangs a small GPUParticles3D
## emitter over the nearest few NEAR-ring deciduous chunks while the canopy is
## actually shedding, and nothing at all the rest of the year.
##
## Deliberately a SCANNER, not a build-time hook: the veg runtimes rebuild their
## MultiMeshes on any style/quality/SoI change, and an emitter parented into
## that tree would be destroyed and re-created with them. Scanning the built
## batch nodes on a slow tick instead means leaf fall survives every rebuild and
## needs no plumbing through the static build path.
##
## Cost is bounded by construction: MAX_EMITTERS live emitters at
## PARTICLES_PER_EMITTER each, only inside RANGE_M, only in the drop window, and
## only when the graphics preset's veg tier enables it (RenderProfile
## veg_profile()["leaf_fall"] — off below High).

const MAX_EMITTERS := 6
const PARTICLES_PER_EMITTER := 48
const RANGE_M := 140.0
## Rescan cadence. Leaf fall is ambience — it does not need to track the camera
## frame by frame, and each scan walks the vegetation batch nodes.
const SCAN_INTERVAL_S := 0.75
## Season gate. Below this the canopy is either full or already bare, and an
## emitter would be raining leaves off a tree that has none.
const DROP_AUTUMN_MIN := 0.05
const DROP_COVERAGE_MIN := 0.02
## Real trees start shedding the moment the canopy turns, so this only has to
## exclude a canopy that is still genuinely full (peak autumn colour arrives
## about a week before coverage has dropped even 5%).
const DROP_COVERAGE_MAX := 0.99
## Only families that actually shed. Conifers keep their needles, so their
## chunks are skipped even inside the drop window.
const SHEDDING_FAMILIES := ["deciduous"]

var enabled := true

var _terrain: Node3D = null
var _accum := 0.0
## chunk key (Vector2i) -> GPUParticles3D
var _emitters: Dictionary = {}
var _leaf_mesh: QuadMesh = null
var _leaf_material: StandardMaterial3D = null


func bind_terrain(terrain: Node3D) -> void:
	_terrain = terrain


func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	if not enabled:
		_clear_emitters()


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_accum += delta
	if _accum < SCAN_INTERVAL_S:
		return
	_accum = 0.0
	if not enabled:
		return
	var season := _season()
	if not _is_dropping(season):
		_clear_emitters()
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		_clear_emitters()
		return
	_refresh_emitters(cam.global_position, season)


## Phenology signals from Main (the same dictionary the veg shaders run on, so
## particles can never disagree with the canopy they fall from).
func _season() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {}
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null or not main.has_method("get_season_signals"):
		return {}
	var s: Variant = main.call("get_season_signals")
	return s as Dictionary if s is Dictionary else {}


## The drop window: leaves are turning AND the canopy is partway down. Spring
## leaf-out passes through the same coverage range in the other direction, which
## is why autumn (a one-sided signal) has to gate it.
static func is_drop_window(autumn: float, coverage: float) -> bool:
	return autumn >= DROP_AUTUMN_MIN \
		and coverage >= DROP_COVERAGE_MIN and coverage <= DROP_COVERAGE_MAX


func _is_dropping(season: Dictionary) -> bool:
	if season.is_empty():
		return false
	return is_drop_window(float(season.get("autumn", 0.0)),
		float(season.get("leaf_coverage", 1.0)))


## BOTH veg roots: "Vegetation" (painted layer) AND "AutoVegetation" (the OSM
## auto-scatter, AutoVegetationRuntime.ROOT_NAME). Scanning only the manual
## root meant auto-scattered deciduous stands — most of the forest on a real
## site — never emitted a single falling leaf.
func _veg_roots() -> Array:
	if _terrain == null or not is_instance_valid(_terrain):
		return []
	var out: Array = []
	for n in ["Vegetation", "AutoVegetation"]:
		var r := _terrain.get_node_or_null(n) as Node3D
		if r != null:
			out.append(r)
	return out


func _refresh_emitters(cam_pos: Vector3, season: Dictionary) -> void:
	var roots := _veg_roots()
	if roots.is_empty():
		_clear_emitters()
		return
	# Candidate chunks: NEAR-ring leaf-shell batches of a shedding family, close
	# enough to see an individual leaf.
	var candidates: Array = []
	for root in roots:
		for child in (root as Node3D).get_children():
			var mi := child as MultiMeshInstance3D
			if mi == null or mi.multimesh == null or mi.multimesh.instance_count <= 0:
				continue
			if not _is_shedding_near_batch(mi):
				continue
			var aabb := mi.get_aabb()
			var center: Vector3 = mi.global_transform * aabb.get_center()
			var d := center.distance_to(cam_pos)
			if d > RANGE_M:
				continue
			candidates.append({"mi": mi, "dist": d, "aabb": aabb, "center": center})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["dist"]) < float(b["dist"]))

	var keep: Dictionary = {}
	var leaf_col := _leaf_color(season)
	for i in mini(candidates.size(), MAX_EMITTERS):
		var c: Dictionary = candidates[i]
		var mi: MultiMeshInstance3D = c["mi"]
		var key := mi.get_instance_id()
		keep[key] = true
		var p: GPUParticles3D = _emitters.get(key, null)
		if p == null or not is_instance_valid(p):
			p = _make_emitter()
			add_child(p)
			_emitters[key] = p
		_place_emitter(p, c["aabb"] as AABB, mi.global_transform, leaf_col)

	for key in _emitters.keys():
		if keep.has(key):
			continue
		var dead: GPUParticles3D = _emitters[key]
		if is_instance_valid(dead):
			dead.queue_free()
		_emitters.erase(key)


## Batch nodes are named Bulk_<species>_<tier>_<cx>_<cz> on the canopy LOD path
## (VegetationRuntime._build_canopy_lod_bulk_batches). Only the NEAR tier of a
## shedding family qualifies: the MID/OUTER rings are cards and impostors seen
## from far enough away that individual leaves are sub-pixel anyway.
static func _is_shedding_near_batch(mi: MultiMeshInstance3D) -> bool:
	var species := VegetationRuntime.species_from_bulk_name(mi.name)
	if species.is_empty():
		return false
	if VegSpeciesCatalog.mesh_family(species) not in SHEDDING_FAMILIES:
		return false
	var parts := mi.name.split("_")
	# ..._<tier>_<cx>_<cz>: the tier token is third from the end.
	if parts.size() < 4:
		return false
	var tier_tok := str(parts[parts.size() - 3])
	if not tier_tok.is_valid_int():
		return false
	return int(tier_tok) == VegetationCardFactory.CanopyLodTier.NEAR


func _leaf_color(season: Dictionary) -> Color:
	# Match the shaders' autumn ramp so the leaves in the air are the colour of
	# the leaves on the tree.
	var autumn := clampf(float(season.get("autumn", 0.0)), 0.0, 1.0)
	var warm := Color(0.96, 0.78, 0.12)
	var hot := Color(0.80, 0.13, 0.04)
	var brown := Color(0.42, 0.26, 0.10)
	# Early in the drop leaves are still yellow; by the end they are brown.
	var late := 1.0 - clampf(float(season.get("leaf_coverage", 1.0)), 0.0, 1.0)
	return warm.lerp(hot, autumn * 0.6).lerp(brown, late * 0.5)


func _make_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = PARTICLES_PER_EMITTER
	p.lifetime = 7.0
	p.randomness = 0.6
	p.fixed_fps = 15
	p.interpolate = true
	p.draw_pass_1 = _shared_leaf_mesh()
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.6
	# A leaf is mostly drag: it drifts down at roughly a third of a metre per
	# second rather than falling, and the turbulence is what sells it.
	pm.gravity = Vector3(0.0, -0.55, 0.0)
	pm.damping_min = 0.2
	pm.damping_max = 0.6
	pm.angular_velocity_min = -90.0
	pm.angular_velocity_max = 90.0
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.35
	pm.turbulence_noise_scale = 1.6
	p.process_material = pm
	return p


func _place_emitter(p: GPUParticles3D, aabb: AABB, xform: Transform3D, col: Color) -> void:
	var center: Vector3 = xform * aabb.get_center()
	var size := aabb.size
	# Emit from the upper half of the canopy volume — leaves detach from the
	# crown, not from the trunk.
	var top := center
	top.y = (xform * (aabb.position + Vector3(size.x * 0.5, size.y * 0.78, size.z * 0.5))).y
	p.global_position = top
	var pm := p.process_material as ParticleProcessMaterial
	if pm != null:
		pm.emission_box_extents = Vector3(
			maxf(size.x * 0.5, 1.0), maxf(size.y * 0.18, 1.0), maxf(size.z * 0.5, 1.0))
		pm.color = col
	p.visibility_aabb = AABB(
		Vector3(-size.x * 0.6, -size.y - 8.0, -size.z * 0.6),
		Vector3(size.x * 1.2, size.y * 1.4 + 12.0, size.z * 1.2))
	p.emitting = true


func _shared_leaf_mesh() -> Mesh:
	if _leaf_mesh != null:
		return _leaf_mesh
	_leaf_mesh = QuadMesh.new()
	_leaf_mesh.size = Vector2(0.16, 0.10)
	_leaf_material = StandardMaterial3D.new()
	_leaf_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_leaf_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Particle colour rides in per-instance vertex colour, so one material
	# serves every emitter regardless of how far into the drop it is.
	_leaf_material.vertex_color_use_as_albedo = true
	_leaf_material.albedo_color = Color(1, 1, 1)
	_leaf_material.roughness = 0.9
	_leaf_mesh.material = _leaf_material
	return _leaf_mesh


func _clear_emitters() -> void:
	for key in _emitters.keys():
		var p: GPUParticles3D = _emitters[key]
		if is_instance_valid(p):
			p.queue_free()
	_emitters.clear()


func active_emitter_count() -> int:
	return _emitters.size()

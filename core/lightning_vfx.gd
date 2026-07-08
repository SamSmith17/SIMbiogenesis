class_name LightningVfx
extends Node3D

## Terrain-peak lightning during thunderstorms: jagged arc + brief flash (no thunder).

signal flash_triggered(intensity: float)

const GRID_N := 9
const GRID_HALF_M := 200.0
const RELIEF_MIN_M := 12.0
const BOLT_LIFETIME := 0.12
const MIN_INTERVAL := 6.0
const MAX_INTERVAL := 22.0

var _strike_mesh: MeshInstance3D
var _strike_mat: StandardMaterial3D
var _flash_light: OmniLight3D
var _bolt_timer := 0.0
var _next_strike := 8.0
var _storm_intensity := 0.0
var _active := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_strike_mesh = MeshInstance3D.new()
	_strike_mesh.name = "BoltMesh"
	_strike_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_strike_mat = StandardMaterial3D.new()
	_strike_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_strike_mat.emission_enabled = true
	_strike_mat.emission = Color(0.75, 0.88, 1.0)
	_strike_mat.emission_energy_multiplier = 4.0
	_strike_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_strike_mat.albedo_color = Color(0.9, 0.95, 1.0, 0.95)
	_strike_mesh.material_override = _strike_mat
	_strike_mesh.visible = false
	add_child(_strike_mesh)

	_flash_light = OmniLight3D.new()
	_flash_light.name = "StrikeFlash"
	_flash_light.light_color = Color(0.82, 0.9, 1.0)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 280.0
	_flash_light.shadow_enabled = false
	add_child(_flash_light)


func set_storm_active(active: bool, intensity: float) -> void:
	_active = active
	_storm_intensity = clampf(intensity, 0.0, 1.0)
	if not active:
		_strike_mesh.visible = false
		_flash_light.light_energy = 0.0


func _process(delta: float) -> void:
	if _bolt_timer > 0.0:
		_bolt_timer -= delta
		var fade := clampf(_bolt_timer / BOLT_LIFETIME, 0.0, 1.0)
		_strike_mesh.visible = fade > 0.02
		_flash_light.light_energy = fade * fade * 6.0 * _storm_intensity
		if _bolt_timer <= 0.0:
			_strike_mesh.visible = false
			_flash_light.light_energy = 0.0
		return

	if not _active or _storm_intensity < 0.15:
		return

	_next_strike -= delta
	if _next_strike > 0.0:
		return
	_try_strike()
	var mean := lerpf(MAX_INTERVAL, MIN_INTERVAL, _storm_intensity)
	_next_strike = _rng.randf_range(mean * 0.6, mean * 1.4)


func _try_strike() -> void:
	var player := _get_player()
	if player == null:
		return
	var center := player.global_position
	var ground_fn := _ground_height_callable()
	if ground_fn == null:
		return

	var best: Vector3 = Vector3.ZERO
	var best_score := -INF
	var cell := (GRID_HALF_M * 2.0) / float(GRID_N - 1)
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(GRID_N * GRID_N)
	var sum := 0.0
	for iz in GRID_N:
		for ix in GRID_N:
			var x := center.x - GRID_HALF_M + float(ix) * cell
			var z := center.z - GRID_HALF_M + float(iz) * cell
			var y: float = float(ground_fn.call(x, z))
			var idx := iz * GRID_N + ix
			heights[idx] = y
			sum += y

	var mean_y := sum / float(heights.size())
	for iz in range(1, GRID_N - 1):
		for ix in range(1, GRID_N - 1):
			var idx := iz * GRID_N + ix
			var y := heights[idx]
			if y < mean_y + RELIEF_MIN_M:
				continue
			var is_peak := true
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dz == 0:
						continue
					if heights[(iz + dz) * GRID_N + (ix + dx)] > y:
						is_peak = false
						break
				if not is_peak:
					break
			if not is_peak:
				continue
			var prominence := y - mean_y
			var score := prominence + _rng.randf() * 3.0
			if score > best_score:
				best_score = score
				var x := center.x - GRID_HALF_M + float(ix) * cell
				var z := center.z - GRID_HALF_M + float(iz) * cell
				best = Vector3(x, y, z)

	if best_score < 0.0:
		# Fallback: highest cell in grid.
		for iz in GRID_N:
			for ix in GRID_N:
				var idx := iz * GRID_N + ix
				if heights[idx] > best_score:
					best_score = heights[idx]
					var x := center.x - GRID_HALF_M + float(ix) * cell
					var z := center.z - GRID_HALF_M + float(iz) * cell
					best = Vector3(x, heights[idx], z)

	if best_score < -1e8:
		return

	var cloud_base := best + Vector3(
		_rng.randf_range(-60, 60), _rng.randf_range(260, 380), _rng.randf_range(-60, 60))
	_spawn_bolt(cloud_base, best)
	_bolt_timer = BOLT_LIFETIME
	flash_triggered.emit(_storm_intensity)


func _spawn_bolt(start: Vector3, end: Vector3) -> void:
	var pts: Array[Vector3] = []
	pts.append(start)
	_fractal_points(pts, start, end, 0, 4)
	pts.append(end)
	_strike_mesh.mesh = _build_tube_mesh(pts, 0.35, 1.2)
	_strike_mesh.global_transform = Transform3D.IDENTITY
	_flash_light.global_position = end + Vector3(0, 2, 0)


func _fractal_points(pts: Array[Vector3], a: Vector3, b: Vector3, depth: int, max_depth: int) -> void:
	if depth >= max_depth:
		return
	var mid := (a + b) * 0.5
	var disp := Vector3(
		_rng.randf_range(-18, 18), _rng.randf_range(-12, 12), _rng.randf_range(-18, 18))
	mid += disp
	_fractal_points(pts, a, mid, depth + 1, max_depth)
	pts.append(mid)
	_fractal_points(pts, mid, b, depth + 1, max_depth)


func _build_tube_mesh(points: Array[Vector3], radius: float, taper: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if points.size() < 2:
		return st.commit()
	var up := Vector3.UP
	for i in range(points.size() - 1):
		var p0: Vector3 = points[i]
		var p1: Vector3 = points[i + 1]
		var seg := p1 - p0
		if seg.length_squared() < 1e-4:
			continue
		var dir := seg.normalized()
		var side := up.cross(dir)
		if side.length_squared() < 1e-4:
			side = Vector3.RIGHT.cross(dir)
		side = side.normalized()
		var r0 := radius * pow(taper, float(i))
		var r1 := radius * pow(taper, float(i + 1))
		var a0 := p0 + side * r0
		var b0 := p0 - side * r0
		var a1 := p1 + side * r1
		var b1 := p1 - side * r1
		st.add_vertex(a0)
		st.add_vertex(b0)
		st.add_vertex(a1)
		st.add_vertex(b0)
		st.add_vertex(b1)
		st.add_vertex(a1)
	return st.commit()


func _ground_height_callable() -> Callable:
	var tree := get_tree()
	if tree == null:
		return Callable()
	var main := tree.root.get_node_or_null("Main")
	if main == null:
		return Callable()
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("_ground_height_at"):
		return Callable(loader, "_ground_height_at")
	return Callable()


func _get_player() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	var p := tree.root.get_node_or_null("Main/Player")
	if p is Node3D:
		return p as Node3D
	return null

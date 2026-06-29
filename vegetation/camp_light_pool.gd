class_name CampLightPool
extends Node3D

## A small fixed pool of real OmniLight3D that follows the active camera and
## snaps onto the nearest camp glow points, so Black Rock City casts genuine
## coloured light near the player without thousands of live lights. The whole
## field's brightness (these lights + the emissive glow MultiMesh uniform) is
## ramped from day → night off the sun altitude, so the city only lights up at
## dusk. Created and fed by BrcCampGenerator.build_camps_node().

## How many real lights to keep alive at once.
@export var max_lights := 40
## Only consider glow points within this radius of the camera.
@export var cull_radius_m := 130.0
## Peak per-light energy at full night.
@export var full_energy := 3.2
## Per-light illumination radius.
@export var light_range_m := 16.0
## Seconds between pool re-targets (re-pointing lights is the costly part).
@export var update_interval_s := 0.2

var _glow: Array = []                # [{pos: Vector3, color: Color}, …]
var _glow_mat: ShaderMaterial = null
var _main: Node = null
var _sun: Node3D = null
var _lights: Array[OmniLight3D] = []
var _accum := 0.0


func setup(glow_points: Array, glow_material: ShaderMaterial, main: Node) -> void:
	_glow = glow_points
	_glow_mat = glow_material
	_main = main
	_ensure_lights()


func _ready() -> void:
	_ensure_lights()
	set_process(true)


func _ensure_lights() -> void:
	if not _lights.is_empty():
		return
	for i in max_lights:
		var l := OmniLight3D.new()
		l.omni_range = light_range_m
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < update_interval_s:
		return
	_accum = 0.0

	var night := _night_factor()
	if _glow_mat != null:
		# Drive the emissive cores well into HDR at full night so they survive
		# tonemapping and bloom into bright coloured points (the aerial "city at
		# night" look) rather than reading as flat, dull dots. The radial mask in
		# camp_glow.gdshader keeps each one a compact point, not a solid wash.
		_glow_mat.set_shader_parameter("glow_intensity", night * 14.0)

	if night < 0.03 or _glow.is_empty():
		for l in _lights:
			l.visible = false
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var r2 := cull_radius_m * cull_radius_m

	# Keep the nearest `max_lights` glow points (insertion into a small buffer).
	var best: Array = []   # [{d2, pos, color}], kept sorted ascending by d2.
	for g in _glow:
		var p: Vector3 = g["pos"]
		var d2 := cam_pos.distance_squared_to(p)
		if d2 > r2:
			continue
		if best.size() < max_lights:
			best.append({"d2": d2, "pos": p, "color": g["color"]})
			if best.size() == max_lights:
				best.sort_custom(_by_d2)
		elif d2 < best[max_lights - 1]["d2"]:
			best[max_lights - 1] = {"d2": d2, "pos": p, "color": g["color"]}
			best.sort_custom(_by_d2)

	var energy := night * full_energy
	for i in _lights.size():
		var l := _lights[i]
		if i < best.size():
			l.global_position = best[i]["pos"]
			l.light_color = best[i]["color"]
			l.light_energy = energy
			l.visible = true
		else:
			l.visible = false


static func _by_d2(a: Dictionary, b: Dictionary) -> bool:
	return a["d2"] < b["d2"]


## 0 by day, 1 at night, with a twilight ramp. Read from the sim's sun light.
func _night_factor() -> float:
	if _sun == null:
		_resolve_sun()
	if _sun == null:
		return 0.0
	# Light travels along the node's -Z; basis.z.y therefore tracks sun altitude
	# (≈ +1 overhead, ≈ -1 at night). See main.gd sun rig.
	var altitude_sin := _sun.global_transform.basis.z.y
	return clampf((0.05 - altitude_sin) / 0.15, 0.0, 1.0)


func _resolve_sun() -> void:
	if _main != null and _main.get("sun") != null:
		_sun = _main.get("sun") as Node3D
		return
	# Fallback: first DirectionalLight3D in the scene.
	var root := get_tree().get_root() if get_tree() != null else null
	if root != null:
		_sun = _first_directional_light(root)


func _first_directional_light(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node as DirectionalLight3D
	for child in node.get_children():
		var found := _first_directional_light(child)
		if found != null:
			return found
	return null

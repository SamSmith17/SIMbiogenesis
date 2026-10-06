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
## Emissive-card peak at full night (camp_glow.gdshader `glow_intensity`).
@export var card_intensity := 14.0
## A light reaches full brightness only inside this fraction of the pool's
## reach and fades to nothing at its edge — so lights GROW in as you approach
## instead of switching on at a fixed distance.
@export var fade_start_frac := 0.45
## Time constant (s) of every brightness change. Any light that is (re)assigned
## eases in from zero and a released one eases out, so a swap is never a pop.
@export var ease_tau_s := 0.7

var _glow: Array = []                # [{pos: Vector3, color: Color, pool?: bool}, …]
var _pool_idx: PackedInt32Array = PackedInt32Array()   # glow indices a light may take
var _glow_mat: ShaderMaterial = null
## Further materials that take the same `glow_intensity` (the painted camps'
## ground light spill).
var _extra_mats: Array = []
var _main: Node = null
var _sun: Node3D = null
var _lights: Array[OmniLight3D] = []
## Per light: the glow index it shows (-1 = free), and its brightness now/target.
var _slot_point: PackedInt32Array = PackedInt32Array()
var _slot_now: PackedFloat32Array = PackedFloat32Array()
var _slot_target: PackedFloat32Array = PackedFloat32Array()
## Reach the fade is measured against: the cull radius, or — when more points
## are in reach than there are lights — the distance of the farthest one kept,
## so the light at the edge of the set is always the dimmest. Smoothed.
var _reach := -1.0
var _accum := 0.0


func setup(glow_points: Array, glow_material: ShaderMaterial, main: Node,
		extra_materials: Array = []) -> void:
	_glow = glow_points
	_glow_mat = glow_material
	_extra_mats = extra_materials
	_main = main
	_pool_idx = PackedInt32Array()
	for i in _glow.size():
		if bool((_glow[i] as Dictionary).get("pool", true)):
			_pool_idx.append(i)
	_ensure_lights()
	# The point list changed: every light lets go and eases back in.
	for i in _slot_point.size():
		_slot_point[i] = -1
		_slot_target[i] = 0.0
	_accum = update_interval_s


func _ready() -> void:
	_ensure_lights()
	set_process(true)


func _ensure_lights() -> void:
	if _lights.size() == max_lights:
		return
	for l in _lights:
		l.queue_free()
	_lights.clear()
	_slot_point.resize(max_lights)
	_slot_now.resize(max_lights)
	_slot_target.resize(max_lights)
	for i in max_lights:
		var l := OmniLight3D.new()
		l.omni_range = light_range_m
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.light_specular = 0.25
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)
		_slot_point[i] = -1
		_slot_now[i] = 0.0
		_slot_target[i] = 0.0


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= update_interval_s:
		_accum = 0.0
		_retarget()
	var k := 1.0 - exp(-delta / maxf(ease_tau_s, 0.01))
	for i in _lights.size():
		var now := lerpf(_slot_now[i], _slot_target[i], k)
		if absf(now - _slot_target[i]) < 0.002:
			now = _slot_target[i]
		_slot_now[i] = now
		var l := _lights[i]
		l.light_energy = now
		var on := now > 0.002
		if l.visible != on:
			l.visible = on
		if not on and _slot_target[i] <= 0.0:
			_slot_point[i] = -1   # fully faded out: free for reuse


func _retarget() -> void:
	var night := _night_factor()
	if _glow_mat != null:
		# Drive the emissive cores well into HDR at full night so they survive
		# tonemapping and bloom into bright coloured points (the aerial "city at
		# night" look) rather than reading as flat, dull dots. The radial mask in
		# camp_glow.gdshader keeps each one a compact point, not a solid wash.
		_glow_mat.set_shader_parameter("glow_intensity", night * card_intensity)
	for m: ShaderMaterial in _extra_mats:
		if m != null:
			m.set_shader_parameter("glow_intensity", night * card_intensity)

	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if night < 0.03 or _pool_idx.is_empty() or cam == null:
		for i in _slot_target.size():
			_slot_target[i] = 0.0
		return
	var cam_pos := cam.global_position
	var r2 := cull_radius_m * cull_radius_m

	# Keep the nearest `max_lights` pool points (insertion into a small buffer).
	var best: Array = []   # [{d2, idx}], kept sorted ascending by d2.
	for idx in _pool_idx:
		var p: Vector3 = (_glow[idx] as Dictionary)["pos"]
		var d2 := cam_pos.distance_squared_to(p)
		if d2 > r2:
			continue
		if best.size() < max_lights:
			best.append({"d2": d2, "idx": idx})
			if best.size() == max_lights:
				best.sort_custom(_by_d2)
		elif d2 < best[max_lights - 1]["d2"]:
			best[max_lights - 1] = {"d2": d2, "idx": idx}
			best.sort_custom(_by_d2)

	var reach := cull_radius_m
	if best.size() >= max_lights:
		reach = minf(reach, sqrt(float(best[max_lights - 1]["d2"])) + 1.0)
	_reach = reach if _reach < 0.0 else lerpf(_reach, reach, 0.35)
	var fade_from := _reach * fade_start_frac
	var peak := night * full_energy

	var wanted: Dictionary = {}   # glow idx -> target energy
	for b: Dictionary in best:
		var d := sqrt(float(b["d2"]))
		wanted[int(b["idx"])] = peak * (1.0 - smoothstep(fade_from, _reach, d))
	# Lights already on a wanted point keep it; everything else fades out.
	for i in _slot_point.size():
		var pt := _slot_point[i]
		if pt >= 0 and wanted.has(pt):
			_slot_target[i] = wanted[pt]
			wanted.erase(pt)
		else:
			_slot_target[i] = 0.0
	# New points take a free light, else the dimmest one on its way out.
	for idx: int in wanted.keys():
		var slot := -1
		var dimmest := INF
		for i in _slot_point.size():
			if _slot_point[i] < 0:
				slot = i
				break
			if _slot_target[i] <= 0.0 and _slot_now[i] < dimmest:
				dimmest = _slot_now[i]
				slot = i
		if slot < 0:
			break
		var g: Dictionary = _glow[idx]
		var c: Color = g["color"]
		var l := _lights[slot]
		l.global_position = g["pos"]
		l.light_color = Color(c.r, c.g, c.b)
		_slot_point[slot] = idx
		_slot_now[slot] = 0.0
		_slot_target[slot] = wanted[idx]


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

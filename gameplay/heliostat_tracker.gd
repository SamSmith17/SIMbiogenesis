class_name HeliostatTracker
extends Node3D

## Dual-axis sun tracker for a placed dish heliostat / solar furnace. Aims the
## mirror dish's optical axis directly at the sun by driving two nested nodes —
## the "horizontal rotating assembly" (azimuth, about the vertical bearing) and
## its child "Vertical Rotating Assembly" (altitude, about the horizontal
## elevation bearing) — then paints the mirrors and lights up the focal point.
## Attached by PlacedPropRuntime to a PlacedProp whose record has
## kind == "heliostat" (mirrors CspTroughTracker, extended from one axis to two).
##
## Model structure (heliostat.glb, verified with a throwaway node/axis probe —
## see core/placed_models/heliostat_dump.gd):
##  ModelRoot(heliostat) → Node(−90° X, Z-up→Y-up) → Component#1(inch→m 0.025)
##    ├─ Component → fixed base                         (never moves)
##    └─ horizontal rotating assembly                   (AZIMUTH: local +Z)
##         └─ Vertical Rotating Assembly (rest .z=−180) (ALTITUDE: local +Y)
##              ├─ Mirror array          (the concentrating facets)
##              └─ solar collector area  (the ~0.5 m focal-point box)
## The axis probe found the mount is a clean alt-azimuth: rotating the azimuth
## node about its LOCAL Z changes only the dish azimuth (+Z → az −1°/1°) and
## rotating the elevation node about its LOCAL Y changes only the dish altitude
## (+Y → el +1°/1°), with the two staying decoupled through the full range. The
## rest dish normal (average of all Mirror-array facet normals, which for a
## symmetric dish points along the optical axis) is measured live at bind so a
## re-export with a different rest pose keeps working — the drive is
##     azimuth_local_z = (rest_az − sun_az)      (about the vertical bearing)
##     altitude_local_y = (sun_el − rest_el)     (about the elevation bearing)
##
## Orientation reference: ModelRoot's yaw is forced to `forced_yaw_deg` every
## frame (as CspTroughTracker does) so the model's local frame stays aligned to
## world (local +X = east, local −Z = north, local +Y = up). That makes the
## dish azimuth measured in model-local space equal the world solar azimuth from
## SolarPosition (0=N, 90=E), so the two-axis aim needs no extra frame juggling.
##
## Slewing is SIM-TIME aware (same technique as CspTroughTracker): the sun is a
## function of the simulation clock, so the actuators ease with a factor driven
## by both real time and elapsed sim-hours, and a large scrub/time-scale jump
## snaps straight onto the sun instead of visibly sweeping.
##
## Focal glow: the concentrated beam makes the receiver box read as a brilliant
## hot point. Same three-part effect as CspTroughTracker — a bright emissive box
## material, a real OmniLight3D, and a camera-facing additive glow card
## (csp_focal_glow.gdshader) — all driven by the SAME focus factor
## (dni × cos_incidence, cloud- and low-sun-attenuated), so it stays physically
## proportional to the energy hitting the focus. The focal point is far hotter
## than the trough's absorber tube, so the glow peaks brighter and whiter.

const _HELIO_SOURCE := preload("res://power_system/sources/heliostat_source.gd")
const _FOCAL_GLOW_SHADER := preload("res://gameplay/csp_focal_glow.gdshader")

## Real-time smoothing constants (s): actuator ease when the sim clock is
## paused / near real-time.
const _TRACK_TAU_REAL := 0.7
const _RESET_TAU_REAL := 4.0
## Sim-time smoothing constants (sim-hours): how far in simulated time the aim is
## allowed to lag the sun. Tiny while tracking; larger for the overnight reset.
const _TRACK_TAU_SIM := 0.05
const _RESET_TAU_SIM := 0.5
## A single-frame sim jump beyond this (scrub / extreme speed) snaps instantly.
const _SNAP_SIM_HOURS := 0.5
## Overnight stow altitude (deg): a point-focus dish parks face-up so it doesn't
## bake dew off a low horizon aim at dawn (azimuth simply holds where it was).
const _NIGHT_STOW_EL_DEG := 88.0

## Peak DNI × cos (W/m²) used to normalize the focal glow.
const _GLOW_REF_WM2 := 1000.0
## Perceptual curve for the VISUALS only (not the physics); <1 biases low focus
## brighter so hazy/partial conditions still clearly glow.
const _GLOW_GAMMA := 0.5
## Focal-box material emission peak (energy multiplier at focus=1). Far above
## the trough — a point focus should read as almost blinding.
const _BOX_EMISSION_PEAK := 60.0
## OmniLight3D peak energy/range at focus=1.
const _BOX_LIGHT_ENERGY_PEAK := 40.0
const _BOX_LIGHT_RANGE_M := 6.0
## Additive glow-card peak brightness/size at focus=1.
const _GLOW_CARD_BRIGHTNESS_PEAK := 46.0
const _GLOW_CARD_WORLD_SIZE := 0.9

var helio_specs: Dictionary = {}
var base_node_name: String = "fixed base"
var azimuth_node_name: String = "horizontal rotating assembly"
var altitude_node_name: String = "Vertical Rotating Assembly"
var mirror_node_name: String = "Mirror array"
var focal_node_name: String = "solar collector area"

var _model_root: Node3D = null
var _az_node: Node3D = null
var _el_node: Node3D = null
var _mirror_node: Node3D = null
var _focal_node: Node3D = null
var _focal_mesh: MeshInstance3D = null
var _box_material: StandardMaterial3D = null
var _box_light: OmniLight3D = null
var _glow_card: MeshInstance3D = null
var _glow_card_material: ShaderMaterial = null
var _focal_local_center: Vector3 = Vector3.ZERO

var _forced_yaw_rad: float = 0.0
var _az_rest_euler: Vector3 = Vector3.ZERO
var _el_rest_euler: Vector3 = Vector3.ZERO
## Elevation pivot: the mirror dish's own centre (measured), so the assembly
## tilts about the dish rather than the GLB's authored node origin — which sits
## off to the focal-box side and made the dish swing around the focus. Stored in
## both the elevation node's LOCAL space and its PARENT space so the drive can
## keep that point fixed while re-orienting each frame (see _process).
var _el_rest_xform: Transform3D = Transform3D.IDENTITY
var _el_pivot_local: Vector3 = Vector3.ZERO
var _el_pivot_parent: Vector3 = Vector3.ZERO
var _rest_az_deg: float = 0.0
var _rest_el_deg: float = 0.0

var _az_rot: float = 0.0      # smoothed local-Z drive on the azimuth node (rad)
var _az_target: float = 0.0
var _el_rot: float = 0.0      # smoothed local-Y drive on the elevation node (rad)
var _el_target: float = 0.0
var _tracking_active := true
var _last_abs_hours: float = INF
var _sim_dh: float = 0.0
var _ready_ok := false


func configure(specs: Dictionary, base_name: String, azimuth_name: String,
		altitude_name: String, mirror_name: String, focal_name: String) -> void:
	helio_specs = specs.duplicate(true)
	if not base_name.is_empty():
		base_node_name = base_name
	if not azimuth_name.is_empty():
		azimuth_node_name = azimuth_name
	if not altitude_name.is_empty():
		altitude_node_name = altitude_name
	if not mirror_name.is_empty():
		mirror_node_name = mirror_name
	if not focal_name.is_empty():
		focal_node_name = focal_name


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var model_root := _find_model_root()
	if model_root == null:
		return
	_model_root = model_root
	_forced_yaw_rad = deg_to_rad(ModelCatalog.forced_yaw_deg("heliostat"))
	# Align the model's local frame to world (see class doc) so measured dish
	# azimuth equals the world solar azimuth.
	_model_root.rotation = Vector3(0.0, _forced_yaw_rad, 0.0)

	_az_node = model_root.find_child(azimuth_node_name, true, false) as Node3D
	_el_node = model_root.find_child(altitude_node_name, true, false) as Node3D
	_mirror_node = model_root.find_child(mirror_node_name, true, false) as Node3D
	_focal_node = model_root.find_child(focal_node_name, true, false) as Node3D
	if _az_node == null or _el_node == null:
		return
	_az_rest_euler = _az_node.rotation
	_el_rest_euler = _el_node.rotation
	_el_rest_xform = _el_node.transform
	_el_pivot_local = _measure_dish_pivot_el_local()
	_el_pivot_parent = _el_rest_xform * _el_pivot_local

	var rest_normal := _measure_rest_dish_normal()
	_rest_az_deg = rad_to_deg(atan2(rest_normal.x, -rest_normal.z))
	_rest_el_deg = rad_to_deg(atan2(rest_normal.y, Vector2(rest_normal.x, rest_normal.z).length()))

	_paint_mirrors()
	_add_focal_glow()
	_ready_ok = true


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	# Keep the model's world yaw fixed so the local frame stays world-aligned
	# (a re-ground / record edit could otherwise re-apply a yaw to ModelRoot).
	if _model_root != null:
		var r := _model_root.rotation
		if absf(r.y - _forced_yaw_rad) > 0.0001 or absf(r.x) > 0.0001 or absf(r.z) > 0.0001:
			_model_root.rotation = Vector3(0.0, _forced_yaw_rad, 0.0)
	if not _ready_ok:
		return
	_refresh_target()

	var dh := absf(_sim_dh)
	var snap := dh > _SNAP_SIM_HOURS
	var tau_real := _TRACK_TAU_REAL if _tracking_active else _RESET_TAU_REAL
	var tau_sim := _TRACK_TAU_SIM if _tracking_active else _RESET_TAU_SIM
	var k := 1.0
	if not snap:
		var x := delta / maxf(tau_real, 0.01) + dh / maxf(tau_sim, 1e-4)
		k = clampf(1.0 - exp(-x), 0.0, 1.0)

	if snap:
		_az_rot = _az_target
		_el_rot = _el_target
	else:
		_az_rot = lerp_angle(_az_rot, _az_target, k)
		_el_rot = lerpf(_el_rot, _el_target, k)

	if is_instance_valid(_az_node):
		_az_node.rotation = _az_rest_euler + Vector3(0.0, 0.0, _az_rot)
	if is_instance_valid(_el_node):
		# Re-orient with the validated euler drive (correct altitude), then shift
		# the node's origin so the measured dish-centre pivot stays fixed — i.e.
		# the dish tilts about its own centre instead of the authored node origin.
		_el_node.rotation = _el_rest_euler + Vector3(0.0, _el_rot, 0.0)
		_el_node.position = _el_pivot_parent - _el_node.transform.basis * _el_pivot_local
	_sync_focal_glow_position()


func _refresh_target() -> void:
	var main := _main_node()
	var sun_el := 0.0
	var sun_az := 180.0
	var weather := {"ghi": 0.0, "cloud": 0.0, "temp": 25.0, "has_real": false}
	_sim_dh = 0.0
	if main != null:
		var lat_v: Variant = main.get("latitude")
		var lon_v: Variant = main.get("longitude")
		var lat: float = float(lat_v) if lat_v != null else 33.36
		var lon: float = float(lon_v) if lon_v != null else -115.74
		var clock_obj: Variant = main.get("clock")
		if clock_obj != null and (clock_obj as Object).has_method("get_julian_day_utc"):
			var jd_utc: float = float((clock_obj as Object).call("get_julian_day_utc"))
			var sp := SolarPosition.get_position(lat, lon, jd_utc)
			sun_el = float(sp.get("elevation_deg", 0.0))
			sun_az = float(sp.get("azimuth_deg", 180.0))
		if clock_obj != null and (clock_obj as Object).has_method("get_absolute_hours"):
			var cur_abs: float = float((clock_obj as Object).call("get_absolute_hours"))
			if is_finite(_last_abs_hours):
				_sim_dh = cur_abs - _last_abs_hours
			_last_abs_hours = cur_abs
		var hour := 12.0
		var month := 6
		var day := 15
		var dt: Variant = main.get("day_time")
		if dt != null:
			hour = float(dt)
		var mo: Variant = main.get("month")
		if mo != null:
			month = clampi(int(mo), 1, 12)
		var dd: Variant = main.get("day")
		if dd != null:
			day = clampi(int(dd), 1, 31)
		var ws := main.get_tree().root.get_node_or_null("/root/WeatherService") if main.get_tree() != null else null
		if ws != null:
			weather = SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)

	if sun_el > 0.0:
		# Point the optical axis straight at the sun in both axes.
		_tracking_active = true
		_az_target = deg_to_rad(_rest_az_deg - sun_az)
		_el_target = deg_to_rad(sun_el - _rest_el_deg)
	else:
		# Below the horizon: hold azimuth, ease to the face-up stow altitude.
		_tracking_active = false
		_el_target = deg_to_rad(_NIGHT_STOW_EL_DEG - _rest_el_deg)

	var result := _HELIO_SOURCE.simulate(helio_specs, sun_az, sun_el, weather)
	_update_glow(result)


## Purely-visual focal glow, physically proportional to instantaneous energy at
## the focus (dni × cos_incidence). See class doc. Real energy accounting lives
## in HeliostatSource.simulate / SystemGraphView._tick_graph_heliostat.
func _update_glow(result: Dictionary) -> void:
	var dni := float(result.get("dni_wm2", 0.0))
	var cos_inc := float(result.get("cos_incidence", 0.0))
	var focus := clampf(dni * cos_inc / _GLOW_REF_WM2, 0.0, 1.0)
	var vis := pow(focus, _GLOW_GAMMA)
	# Warm ember at low focus → near-white blue-hot core at full focus (a point
	# focus runs hotter/whiter than the trough tube).
	var hot_color := Color(1.0, 0.6, 0.25).lerp(Color(0.97, 0.99, 1.0), vis)

	if _box_material != null:
		_box_material.emission = hot_color
		_box_material.emission_energy_multiplier = lerpf(0.0, _BOX_EMISSION_PEAK, vis)
		_box_material.albedo_color = Color(0.55, 0.55, 0.58).lerp(Color(1.0, 1.0, 1.0), vis)
	if is_instance_valid(_box_light):
		_box_light.light_color = hot_color
		_box_light.light_energy = lerpf(0.0, _BOX_LIGHT_ENERGY_PEAK, vis)
		_box_light.visible = vis > 0.01
	if _glow_card_material != null:
		_glow_card_material.set_shader_parameter("brightness",
			lerpf(0.0, _GLOW_CARD_BRIGHTNESS_PEAK, vis))
		_glow_card_material.set_shader_parameter("tint", Vector3(hot_color.r, hot_color.g, hot_color.b))
	if is_instance_valid(_glow_card):
		_glow_card.visible = vis > 0.01


func _find_model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	if mr != null:
		return mr
	return p as Node3D


## Average of all Mirror-array facet normals expressed in ModelRoot-local space
## (== world directions once the yaw is forced — see class doc). For a symmetric
## dish the transverse facet tilts cancel, so the average points along the
## optical axis. Composes local `transform`s by hand (NOT global_transform,
## which reads stale this early from the deferred _bind).
func _measure_rest_dish_normal() -> Vector3:
	if _mirror_node == null or _model_root == null:
		return Vector3(-1.0, 0.0, 0.0)
	var sum := Vector3.ZERO
	for n in _mirror_node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b := _local_chain_transform(mi, _model_root).basis.orthonormalized()
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			for nv in normals:
				sum += (b * nv)
	if sum.length_squared() < 1e-9:
		return Vector3(-1.0, 0.0, 0.0)
	return sum.normalized()


## Composes LOCAL `transform`s from `node` up to (and including) `stop_at`.
func _local_chain_transform(node: Node3D, stop_at: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p is Node3D:
		var p3 := p as Node3D
		t = p3.transform * t
		if p3 == stop_at:
			break
		p = p3.get_parent()
	return t


func _paint_mirrors() -> void:
	if _mirror_node == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.97, 0.98, 1.0)
	mat.metallic = 1.0
	mat.metallic_specular = 1.0
	mat.roughness = 0.03
	# The dish facets are authored as single-sided quads (invisible from behind);
	# render both faces so the dish reads solid from any viewing angle.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for n in _mirror_node.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).material_override = mat


## The mirror dish's geometric centre, expressed in the elevation node's OWN
## local space (AABB-merged facet boxes composed up to — but excluding — the
## elevation node). Used as the tilt pivot so the dish rotates about itself.
func _measure_dish_pivot_el_local() -> Vector3:
	if _mirror_node == null or _el_node == null:
		return Vector3.ZERO
	var aabb := AABB()
	var found := false
	for n in _mirror_node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = _chain_excluding(mi, _el_node) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	if not found:
		return Vector3.ZERO
	return aabb.get_center()


## Composes LOCAL `transform`s from `node` up to but NOT including `stop_at`,
## i.e. `node` expressed in `stop_at`'s local space.
func _chain_excluding(node: Node3D, stop_at: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != stop_at and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## Locates the focal box mesh + adds the OmniLight + additive glow card as
## children of `self` (real-world-metre space — see CspTroughTracker class doc
## for why NOT the box mesh, whose node chain carries baked inch→m scale).
func _add_focal_glow() -> void:
	if _focal_node != null:
		for n in _focal_node.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				_focal_mesh = mi
				break
	if _focal_mesh != null:
		_focal_local_center = _focal_mesh.mesh.get_aabb().get_center()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.55, 0.55, 0.58)
		mat.metallic = 0.4
		mat.roughness = 0.4
		mat.emission_enabled = true
		mat.emission = Color(1.0, 1.0, 1.0)
		mat.emission_energy_multiplier = 0.0
		_focal_mesh.material_override = mat
		_box_material = mat

	var light := OmniLight3D.new()
	light.name = "HeliostatFocalLight"
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 0.0
	light.omni_range = _BOX_LIGHT_RANGE_M
	light.omni_attenuation = 1.2
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED
	light.light_specular = 0.4
	light.distance_fade_enabled = true
	light.distance_fade_begin = _BOX_LIGHT_RANGE_M * 4.0
	light.distance_fade_length = _BOX_LIGHT_RANGE_M * 2.0
	light.visible = false
	add_child(light)
	_box_light = light

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var card_mat := ShaderMaterial.new()
	card_mat.shader = _FOCAL_GLOW_SHADER
	card_mat.set_shader_parameter("world_size", _GLOW_CARD_WORLD_SIZE)
	card_mat.set_shader_parameter("brightness", 0.0)
	var card := MeshInstance3D.new()
	card.name = "HeliostatFocalGlowCard"
	card.mesh = quad
	card.material_override = card_mat
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	card.visible = false
	add_child(card)
	_glow_card = card
	_glow_card_material = card_mat
	_sync_focal_glow_position()


## Recomputes the moving focal box's position each frame (in `self`'s local
## metre space) from pure local-transform composition — see class doc.
func _sync_focal_glow_position() -> void:
	if _focal_mesh == null or _model_root == null:
		return
	if not is_instance_valid(_box_light) and not is_instance_valid(_glow_card):
		return
	var pos := _local_chain_transform(_focal_mesh, _model_root) * _focal_local_center
	if is_instance_valid(_box_light):
		_box_light.position = pos
	if is_instance_valid(_glow_card):
		_glow_card.position = pos


func _main_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var m := tree.get_first_node_in_group("main_scene")
	if m != null:
		return m
	return tree.current_scene

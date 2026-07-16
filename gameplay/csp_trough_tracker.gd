class_name CspTroughTracker
extends Node3D

## Auto-orients a placed single-axis parabolic-trough CSP so its pivot axis
## runs east-west (the tracking law in csp_trough_source.gd assumes this — see
## that file's class doc), then drives the moving concentrator to tilt and
## track the sun's altitude in real time, and paints the mirror + focal-tube
## materials. Attached by PlacedPropRuntime to a PlacedProp whose record has
## kind == "csp_trough" (mirrors WindTurbineSpin's pattern for the VAWT).
##
## Orientation: the GLB's natural pose already runs Component#453's local +X
## (the ~12 m module-length axis / mechanical pivot) along world east-west, so
## ModelCatalog.forced_yaw_deg("csp_trough") is 0 (no yaw) — verified
## empirically with a throwaway diagnostic that instantiated the GLB and
## measured Component#453's local-X direction + its mirror mesh's average
## normal in world space at several yaws. PlacedPropService._build_ghost
## applies the SAME forced-yaw constant to the placement ghost, so the preview
## never visibly rotates when confirmed.
##
## Rest-pose bias: at forced yaw the mesh's OWN rest pose (Component#453.rotation
## == 0) does NOT correspond to "aperture normal pointing straight up" — the
## diagnostic measured the rest mirror-normal tilted ~64° toward south (an
## artifact of the pose the asset happened to be exported in). `_rest_offset_rad`
## is measured from the actual mesh geometry at bind time (average local normal
## of the 'Metal_06_1K' mirror mesh, decomposed against the E-W axis) rather
## than hardcoded, so a re-export with a different rest pose keeps working.
## Because rotating a fixed vector about a fixed axis is a pure additive
## parameterization, the identity
##     ideal_theta_deg == Component#453.rotation.x_deg + rest_offset_deg
## (ideal_theta following CspTroughSource.tracking_angle_deg's atan2(south, up)
## convention) holds for the full range — confirmed by perturbing rotation.x by
## ±10° in the diagnostic and re-measuring the world normal. So:
##     Component#453.rotation.x = ideal_theta - rest_offset.
##
## Slewing is SIM-TIME aware: the sun position is a function of the simulation
## clock (which can run at large time-scales or be scrubbed forward/backward),
## so a purely real-time smoothing constant lagged badly at speed and crawled
## across scrubs. Each frame the target is refreshed and the concentrator eases
## toward it with a smoothing factor driven by BOTH real time (so it visibly
## eases in when the clock is paused/slow) AND elapsed sim-hours (so it keeps
## locked to the sun at any time-scale); a large sim-time jump snaps instantly.
##
## Focal-tube "blinding" glow: a plain self-emissive StandardMaterial3D reads
## as flat white, not brilliant — this project's WorldEnvironment deliberately
## keeps DAYTIME bloom to a compact core (fine mips only, no wide veil, and a
## capped HDR luminance — see main.gd's `_update_glow`/glow setup comments) so
## ordinary bright surfaces don't wash the whole scene out in daylight. Pushing
## the material's raw emission higher doesn't help much past that cap. So on
## top of a bright emissive tube material, two more elements sell the effect:
## an actual `OmniLight3D` at the tube (lights the mirror/mount it sits in
## front of, the real "this is a light source" cue) and a small camera-facing
## additive glow card (`csp_focal_glow.gdshader`, same soft-radial-falloff
## trick as `vegetation/camp_glow.gdshader`'s night lights) that paints a
## convincing soft "hot point" directly into the HDR framebuffer, independent
## of how conservative the global daytime bloom tuning is. All three (material
## emission, light energy, card brightness) are driven by the SAME focus
## factor (`dni_wm2 * cos_incidence`, already cloud- and low-sun-angle-
## attenuated — see `CspTroughSource`), so the effect is physically
## proportional to instantaneous energy received.
##
## Positioning gotcha: the GLB has an internal "Node2" ancestor between
## ModelRoot and Component#453 carrying a baked 0.0254 (inch->metre) scale
## (verified empirically) — a light/card parented directly under `_tube_mesh`
## would have its `omni_range`/card size silently divided by ~39. So the light
## and card are children of `self` (a sibling of ModelRoot under PlacedProp,
## already in real-world metres — see PlacedPropRuntime._apply_transform)
## instead, and their LOCAL position is recomputed every `_process` from
## `_local_chain_transform(_tube_mesh, _model_root)` (pure local-transform
## composition, the same technique `_measure_rest_offset_rad` already uses —
## robust regardless of the GLB's internal scale/rest-pose quirks and not
## dependent on `global_transform` cache timing).

const _CSP_SOURCE := preload("res://power_system/sources/csp_trough_source.gd")
const _FOCAL_GLOW_SHADER := preload("res://gameplay/csp_focal_glow.gdshader")

## Real-time smoothing constants (s): how fast the actuator eases toward the
## target when the sim clock is paused or near real-time.
const _TRACK_TAU_REAL := 0.6
const _RESET_TAU_REAL := 4.0
## Sim-time smoothing constants (sim-hours): how far (in simulated time) the
## tracker is allowed to lag the sun. Tiny while tracking (stays glued to the
## sun at any speed); larger for the overnight reset so it drifts gradually.
const _TRACK_TAU_SIM := 0.05
const _RESET_TAU_SIM := 0.5
## A single-frame sim-time jump beyond this (timeline scrub / extreme speed)
## snaps the concentrator straight onto the target instead of easing.
const _SNAP_SIM_HOURS := 0.5
## Ideal tracking angle (deg, CspTroughSource convention) to ease toward once
## the sun sets. For an E-W-axis trough the sun rises due east — off its axis —
## so the best/rest dawn pose is flat (aperture facing straight up, angle 0).
const _SUNRISE_STOW_ANGLE_DEG := 0.0
## Peak DNI (W/m²) used to normalize the focal-tube glow: at full clear-sky
## sun with the mirror well aimed, dni*cos_incidence approaches this.
const _GLOW_REF_WM2 := 1000.0
## A gentle perceptual curve (focus^_GLOW_GAMMA) applied ONLY to the visual
## brightness (material emission / light energy / glow card) — not to the
## underlying physics — so mid-focus conditions (thin cloud, decent but
## imperfect tracking) still read as clearly glowing instead of looking dim
## until focus is nearly 1.0. <1 biases the low end brighter.
const _GLOW_GAMMA := 0.6
## Focal-tube material emission peak (energy multiplier at focus=1).
const _TUBE_EMISSION_PEAK := 26.0
## OmniLight3D peak energy/range at focus=1 — an actual light so the mirror
## and mount around the tube read as genuinely lit, not just a bright decal.
const _TUBE_LIGHT_ENERGY_PEAK := 14.0
const _TUBE_LIGHT_RANGE_M := 3.5
## Additive glow-card peak brightness/size at focus=1.
const _GLOW_CARD_BRIGHTNESS_PEAK := 16.0
const _GLOW_CARD_WORLD_SIZE := 0.55

var csp_specs: Dictionary = {}
var base_node_name: String = "Component#452"
var concentrator_node_name: String = "Component#453"

var _model_root: Node3D = null
var _concentrator: Node3D = null
var _mirror_mesh: MeshInstance3D = null
var _tube_mesh: MeshInstance3D = null
var _tube_material: StandardMaterial3D = null
var _tube_light: OmniLight3D = null
var _glow_card: MeshInstance3D = null
var _glow_card_material: ShaderMaterial = null
var _tube_local_center: Vector3 = Vector3.ZERO
var _forced_yaw_rad: float = 0.0
var _rest_offset_rad: float = 0.0
var _angle: float = 0.0          # smoothed IDEAL angle (tracking_angle_deg convention)
var _target_angle: float = 0.0
var _tracking_active := true     # false while sun is below the horizon (stowed)
var _last_abs_hours: float = INF # sim clock reading last frame (for jump detection)
var _sim_dh: float = 0.0         # signed sim-hours elapsed since last frame
var _ready_ok := false


func configure(specs: Dictionary, base_name: String, concentrator_name: String) -> void:
	csp_specs = specs.duplicate(true)
	if not base_name.is_empty():
		base_node_name = base_name
	if not concentrator_name.is_empty():
		concentrator_node_name = concentrator_name


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var model_root := _find_model_root()
	if model_root == null:
		return
	_model_root = model_root
	_forced_yaw_rad = deg_to_rad(ModelCatalog.forced_yaw_deg("csp_trough"))
	_model_root.rotation = Vector3(0.0, _forced_yaw_rad, 0.0)
	_concentrator = model_root.find_child(concentrator_node_name, true, false) as Node3D
	if _concentrator == null:
		return
	_resolve_meshes()
	_rest_offset_rad = _measure_rest_offset_rad()
	# Start parked in the mesh's rest angle (angle 0) so there's no pop on the
	# first tracked frame; smoothing eases toward the real sun immediately.
	_angle = 0.0
	_paint_mirror()
	_paint_focal_tube()
	_add_focal_glow()
	_ready_ok = true


func _process(delta: float) -> void:
	if _model_root != null:
		# Force the fixed yaw every frame — wins over any yaw a re-ground or
		# record edit might otherwise re-apply to ModelRoot (a single-axis E-W
		# trough's heading is physically fixed; only its tilt tracks).
		var r := _model_root.rotation
		if absf(r.y - _forced_yaw_rad) > 0.0001 or absf(r.x) > 0.0001 or absf(r.z) > 0.0001:
			_model_root.rotation = Vector3(0.0, _forced_yaw_rad, 0.0)
	if not _ready_ok or not is_instance_valid(_concentrator):
		return
	_refresh_target()
	var dh := absf(_sim_dh)
	if dh > _SNAP_SIM_HOURS:
		# Timeline scrub or extreme time-scale: land on the sun instantly.
		_angle = _target_angle
	else:
		var tau_real := _TRACK_TAU_REAL if _tracking_active else _RESET_TAU_REAL
		var tau_sim := _TRACK_TAU_SIM if _tracking_active else _RESET_TAU_SIM
		# Combine real-time and sim-time responsiveness: whichever advances the
		# smoothing more this frame dominates, so the tracker both eases in when
		# the clock is idle AND stays locked to a fast-moving/scrubbed sun.
		var x := delta / maxf(tau_real, 0.01) + dh / maxf(tau_sim, 1e-4)
		var k := 1.0 - exp(-x)
		_angle = lerp_angle(_angle, _target_angle, clampf(k, 0.0, 1.0))
	_concentrator.rotation = Vector3(_angle - _rest_offset_rad, 0.0, 0.0)
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
		# Track elapsed SIMULATION time (absolute hours) for jump/speed-aware
		# slewing — this is what actually drives the sun, not real frame time.
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

	var max_angle := float(csp_specs.get("max_tracking_angle_deg", 110.0))
	if sun_el > 0.0:
		# Actively tracking: chase the real sun's altitude.
		_tracking_active = true
		_target_angle = deg_to_rad(_CSP_SOURCE.tracking_angle_deg(sun_az, sun_el, max_angle))
	else:
		# Below the horizon: stop chasing the (now meaningless) sun position —
		# ease toward the sunrise-ready pose (flat, facing up for an E-W axis)
		# via the much slower reset smoothing so the trough resets overnight.
		_tracking_active = false
		_target_angle = deg_to_rad(clampf(_SUNRISE_STOW_ANGLE_DEG, -max_angle, max_angle))

	var result := _CSP_SOURCE.simulate(csp_specs, sun_az, sun_el, weather)
	_update_glow(result)


## Focal-tube glow: when sunlight is well focused on the tube (high DNI × well-
## aimed mirror) it should read as brilliant, almost blinding — not just flat
## white. `focus` (0..1) already folds in cloud cover and low-sun-angle
## attenuation (both live in `dni_wm2`) plus tracking/incidence quality (from
## `cos_incidence`), so all three visual channels below stay physically
## proportional to instantaneous energy received. This is a purely visual
## "concentrated light" effect — the real energy accounting lives in
## CspTroughSource.simulate / SystemGraphView._tick_graph_csp.
func _update_glow(result: Dictionary) -> void:
	var dni := float(result.get("dni_wm2", 0.0))
	var cos_inc := float(result.get("cos_incidence", 0.0))
	var focus := clampf(dni * cos_inc / _GLOW_REF_WM2, 0.0, 1.0)
	# Perceptual boost for the VISUALS only — the physics stays linear in `focus`.
	var vis := pow(focus, _GLOW_GAMMA)
	# Warm ember at low focus (barely-tracked / hazy) ramping to a near-white,
	# faintly blue-hot core at full focus — like heated metal going white-hot.
	var hot_color := Color(1.0, 0.55, 0.2).lerp(Color(0.96, 0.99, 1.0), vis)

	if _tube_material != null:
		_tube_material.emission = hot_color
		_tube_material.emission_energy_multiplier = lerpf(0.0, _TUBE_EMISSION_PEAK, vis)
		_tube_material.albedo_color = Color(0.6, 0.6, 0.62).lerp(Color(1.0, 1.0, 1.0), vis)

	if is_instance_valid(_tube_light):
		_tube_light.light_color = hot_color
		_tube_light.light_energy = lerpf(0.0, _TUBE_LIGHT_ENERGY_PEAK, vis)
		_tube_light.visible = vis > 0.01

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


## Minimum length/cross aspect ratio for a mesh to count as an absorber "tube".
## The two thin cylinders in this model (the axis-of-rotation torque tube and
## the focal absorber tube) both exceed ~120; the next-thinnest structural part
## is ~6, so 15 cleanly isolates just the tubes.
const _TUBE_MIN_ASPECT := 15.0

## Locates the mirror + focal-tube MeshInstance3D children of the moving
## concentrator. The curved mirror panel carries material 'Metal_06_1K'. For
## the tube we DON'T trust material name: the model has TWO thin cylinders — a
## torque tube ON the rotation axis (perpendicular offset ~0) and the actual
## solar-collector/absorber tube held in front of the mirrors at the focal line
## (~188 cm from the axis, measured empirically). We want the LATTER, so among
## the thin/long meshes we pick the one whose center is FARTHEST from the pivot
## (local X) axis. This is robust to the model's autogenerated node names and to
## the absorber being authored as a glass-envelope material rather than
## '<LightGray>' (which is actually the on-axis torque tube).
func _resolve_meshes() -> void:
	if _concentrator == null:
		return
	var best_tube: MeshInstance3D = null
	var best_perp := -1.0
	for n in _concentrator.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var mat := mi.mesh.surface_get_material(0)
		var mat_name := mat.resource_name if mat != null else ""
		if mat_name == "Metal_06_1K":
			_mirror_mesh = mi
			continue
		var aabb := mi.mesh.get_aabb()
		var sorted_extent: PackedFloat32Array = PackedFloat32Array(
			[aabb.size.x, aabb.size.y, aabb.size.z])
		sorted_extent.sort()
		var length := sorted_extent[2]
		var cross_max := sorted_extent[1]
		if cross_max <= 0.001 or length / cross_max < _TUBE_MIN_ASPECT:
			continue
		# Perpendicular distance of this tube's center from the pivot axis
		# (local X), in the concentrator's own rotating frame. The focal tube
		# is offset ~focal length; the torque tube is on-axis (~0).
		var center_local: Vector3 = _relative_to_pivot(mi) * (aabb.position + aabb.size * 0.5)
		var perp := sqrt(center_local.y * center_local.y + center_local.z * center_local.z)
		if perp > best_perp:
			best_perp = perp
			best_tube = mi
	_tube_mesh = best_tube


## Transform of `node` expressed in the concentrator's LOCAL (pivot) frame —
## composes local transforms up to but NOT including `_concentrator`, so the
## origin is the rotation axis (pure math, valid before the node ticks).
func _relative_to_pivot(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != _concentrator and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## Measures how far the mirror mesh's REST pose (Component#453.rotation == 0)
## sits from "aperture normal pointing straight up", in the same signed
## convention CspTroughSource.tracking_angle_deg uses. Reads raw mesh vertex
## normals (unaffected by node rotation) and composes local `transform`s up the
## chain to `_model_root` by hand — deliberately NOT `global_transform`, which
## only refreshes on a tree process tick and would read stale/identity values
## called this early (from the deferred `_bind`).
func _measure_rest_offset_rad() -> float:
	if _mirror_mesh == null or _concentrator == null or _model_root == null:
		return 0.0
	var local_normal := _average_local_normal(_mirror_mesh, "Metal_06_1K")
	if local_normal == Vector3.ZERO:
		return 0.0
	var t := _local_chain_transform(_mirror_mesh, _model_root)
	var rest_normal_world := (t.basis * local_normal).normalized()
	# Axis is the E-W tracking pivot once ModelRoot's yaw is forced — shared
	# with the physics so 3D and math never drift apart.
	return _CSP_SOURCE.tracking_offset_from_normal(rest_normal_world, _CSP_SOURCE.TRACKING_AXIS)


func _average_local_normal(mi: MeshInstance3D, mat_name: String) -> Vector3:
	if mi.mesh == null:
		return Vector3.ZERO
	var sum := Vector3.ZERO
	var count := 0
	for surf in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(surf)
		if mat == null or mat.resource_name != mat_name:
			continue
		var arrays := mi.mesh.surface_get_arrays(surf)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for n in normals:
			sum += n
			count += 1
	if count == 0:
		return Vector3.ZERO
	return (sum / float(count)).normalized()


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


func _paint_mirror() -> void:
	if _mirror_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.97, 0.98, 1.0)
	mat.metallic = 1.0
	mat.metallic_specular = 1.0
	mat.roughness = 0.02
	_mirror_mesh.material_override = mat


func _paint_focal_tube() -> void:
	if _tube_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.6, 0.62)
	mat.metallic = 0.6
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 0.0
	_tube_mesh.material_override = mat
	_tube_material = mat


## Adds the two "sells the brilliance" elements from the class doc — an
## OmniLight3D that actually lights the mirror/mount, and a small additive
## glow card — as children of `self` (real-world-metre space; see class doc
## for why NOT `_tube_mesh`). Their position is kept in sync with the moving
## tube every frame by `_sync_focal_glow_position`.
func _add_focal_glow() -> void:
	if _tube_mesh == null or _tube_mesh.mesh == null:
		return
	_tube_local_center = _tube_mesh.mesh.get_aabb().get_center()

	var light := OmniLight3D.new()
	light.name = "CspFocalGlowLight"
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 0.0
	light.omni_range = _TUBE_LIGHT_RANGE_M
	light.omni_attenuation = 1.2
	light.shadow_enabled = false
	light.light_bake_mode = Light3D.BAKE_DISABLED
	light.light_indirect_energy = 1.0
	light.light_volumetric_fog_energy = 0.0
	light.light_specular = 0.3
	light.distance_fade_enabled = true
	light.distance_fade_begin = _TUBE_LIGHT_RANGE_M * 4.0
	light.distance_fade_length = _TUBE_LIGHT_RANGE_M * 2.0
	light.visible = false
	add_child(light)
	_tube_light = light

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var card_mat := ShaderMaterial.new()
	card_mat.shader = _FOCAL_GLOW_SHADER
	card_mat.set_shader_parameter("world_size", _GLOW_CARD_WORLD_SIZE)
	card_mat.set_shader_parameter("brightness", 0.0)
	var card := MeshInstance3D.new()
	card.name = "CspFocalGlowCard"
	card.mesh = quad
	card.material_override = card_mat
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	card.visible = false
	add_child(card)
	_glow_card = card
	_glow_card_material = card_mat
	_sync_focal_glow_position()


## Recomputes the tube's world-facing position each frame (in `self`'s local
## metre space) from pure local-transform composition — see class doc.
func _sync_focal_glow_position() -> void:
	if _tube_mesh == null or _model_root == null:
		return
	if not is_instance_valid(_tube_light) and not is_instance_valid(_glow_card):
		return
	var pos := _local_chain_transform(_tube_mesh, _model_root) * _tube_local_center
	if is_instance_valid(_tube_light):
		_tube_light.position = pos
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

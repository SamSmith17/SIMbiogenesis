extends Control

## Hydro Lab "Turbine close-up": the PowerSpout seen side-on with its housing
## ghosted away, the real 24-spoon Pelton runner spinning at a speed derived from
## the jet and the electrical LOAD, a coherent water jet from the nozzle to the
## buckets, splash-back where it strikes, and tailwater falling out the bottom.
##
## Why the machine reads honestly:
##  - the runner is the GLB's own `Pelton Wheel, 24 Spoon` node, spun about the
##    axis the catalog records (model-local X), exactly as SiphonTurbineSpin does
##    in the world;
##  - the jet's scroll rate is PeltonPhysics.jet_velocity_ms(h_net) — more head
##    really does make a visibly faster jet;
##  - shaft speed is PeltonPhysics.omega_rad_s_at_ratio(v_jet, PCD, x) where x
##    comes from speed_ratio_for_load, so shedding the load runs the wheel away
##    toward 2·x_opt while runner_efficiency collapses to zero. That pairing is
##    the whole teaching point and it falls out of the existing physics.
##
## Studio pattern is the canonical in-modal one (linkage_hardware_modal): a
## SubViewportContainer over an own_world_3d SubViewport with a three-point rig.
## Deliberately NOT graph_soi_preview_service — that service carries the AMD-TDR
## crop/clamp scar tissue and a shared World3D; an own_world_3d studio does not.

const MODEL_ID := "powerspout_plt"
## Long-edge cap, well under the section service's 1280 px TDR ceiling.
const VIEWPORT_LONG_PX := 1024
const ORBIT_LIMIT_DEG := 35.0
const DIST_MIN := 0.25
const DIST_MAX := 2.5
## Runner inertia. Shedding load accelerates a 0.28 m wheel over seconds, not
## instantly; loading it back down is quicker because the generator resists.
const TAU_LOAD_S := 0.6
const TAU_SHED_S := 2.5
## Displayed-rotation ceiling and knee (rpm) — see _display_omega. 55 rpm on a
## 24-bucket wheel is ~22 bucket-passes/s, comfortably under the 30/s Nyquist
## limit at 60 fps, so the cups themselves read as moving rather than strobing.
const DISPLAY_RPM_MAX := 55.0
const DISPLAY_RPM_KNEE := 520.0
const SPLASH_MAX := 220
## Nozzle body (metres). A PowerSpout's spear nozzle is a stubby thing — the
## length is fixed while the JET's length follows the runner radius, so the two
## must not share a scale.
const NOZZLE_LEN_M := 0.055
const NOZZLE_TIP_R := 0.011
const NOZZLE_BODY_R := 0.024
const NOZZLE_STUB_M := 0.05

var _viewport: SubViewport
var _container: SubViewportContainer
var _studio: Node3D
var _camera: Camera3D
var _model_root: Node3D
var _runner: Node3D
## Every mesh that is NOT the runner — derived, not name-matched (see _build_model).
var _housing_meshes: Array[MeshInstance3D] = []
var _hud: Label

var _jet: MeshInstance3D
var _jet_mat: ShaderMaterial
var _jet2: MeshInstance3D
var _jet2_mat: ShaderMaterial
var _nozzle: Node3D
var _nozzle2: Node3D
var _splash: GPUParticles3D
var _splash_mat: ParticleProcessMaterial
var _tailwater: GPUParticles3D
var _tailwater_mat: ParticleProcessMaterial

var _ghost_mat: StandardMaterial3D
var _mode_btns: Array[Button] = []
var _display_mode := "cutaway"

## Live state pushed by the Lab (set_state).
var _state: Dictionary = {}
var _omega := 0.0        ## DISPLAY rate (compressed) — what the mesh turns at
var _true_rpm := 0.0     ## physical shaft speed — what the HUD reports
var _angle := 0.0
var _t := 0.0
var _built := false
var _active := false

## Measured once from the instantiated model.
var _runner_axis_local := Vector3(1, 0, 0)
var _runner_centre := Vector3.ZERO
## Same point expressed in the runner's PARENT frame — the only space in which
## `_runner.transform` may be rotated about it (see _measure_runner).
var _runner_centre_parent := Vector3.ZERO
var _runner_radius := 0.14
var _runner_rest := Transform3D.IDENTITY
var _housing_bottom := Vector3.ZERO
## Height of the real `res_in_0` inlet port relative to the runner centre (m).
var _port_dy := 0.0
## Player's fine-tune on top of the measured port height (m), from the Lab.
var _nozzle_offset_m := 0.0

var _orbit_yaw := 0.0
var _orbit_pitch := -6.0
var _dist := 0.55
var _dragging := false
var _last_mouse := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_process(false)
	visible = false


## Build the studio lazily — opening the Hydro Lab must not pay for a tab nobody
## has looked at yet.
func set_active(on: bool) -> void:
	_active = on
	visible = on
	if on and not _built:
		_build_studio()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE \
				if on else SubViewport.UPDATE_DISABLED
	if not on:
		_free_particles()
	set_process(on)


func _build_studio() -> void:
	_built = true
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_container.gui_input.connect(_on_viewport_input)
	vbox.add_child(_container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(VIEWPORT_LONG_PX, int(VIEWPORT_LONG_PX * 0.62))
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_container.add_child(_viewport)

	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.035, 0.043, 0.063)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	e.ambient_light_energy = 0.6
	env.environment = e
	_studio.add_child(env)

	# Three-point rig (key / fill / rim) — same angles as the model preview service.
	_add_light(Vector3(-52, -35, 0), 1.5)
	_add_light(Vector3(-18, 140, 0), 0.45)
	_add_light(Vector3(-10, 180, 0), 0.18)

	_camera = Camera3D.new()
	_camera.near = 0.01
	_camera.far = 50.0
	_camera.fov = 42.0
	_studio.add_child(_camera)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	vbox.add_child(foot)
	_hud = Label.new()
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hud.add_theme_font_size_override("font_size", 11)
	_hud.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95))
	_hud.text = "—"
	foot.add_child(_hud)
	# How much machine to show. Cutaway is the default because it is the reason
	# this view exists, but a Pelton bucket's shape is worth seeing bare, and the
	# intact housing is what the player actually placed in the world.
	_mode_btns.clear()
	for spec: Array in [["Housing", "housing", "The machine as it stands in the world."],
			["Cutaway", "cutaway", "Housing ghosted so the runner and jet are visible."],
			["Runner", "runner", "Housing hidden entirely — just the wheel and the jet."]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.tooltip_text = str(spec[2])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 11)
		var mode := str(spec[1])
		b.pressed.connect(func() -> void: set_display_mode(mode))
		b.set_meta("mode", mode)
		foot.add_child(b)
		_mode_btns.append(b)

	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.62, 0.70, 0.82, 0.16)
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# Front-face culling on a ghost shell is what makes an enclosure read as CUT
	# OPEN rather than as fog: you see the far wall through the near one.
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_FRONT

	_build_model()
	_build_water()
	_apply_display_mode("cutaway")
	_frame_camera()


func _add_light(rot_deg: Vector3, energy: float) -> void:
	var l := DirectionalLight3D.new()
	l.rotation_degrees = rot_deg
	l.light_energy = energy
	l.shadow_enabled = false
	_studio.add_child(l)


func _build_model() -> void:
	var inst: Node3D = ModelCatalog.instantiate(MODEL_ID)
	if inst == null:
		return
	_model_root = Node3D.new()
	_model_root.name = "ModelRoot"
	_studio.add_child(_model_root)
	inst.scale = Vector3.ONE * ModelCatalog.resolved_scale(MODEL_ID, 1.0)
	_model_root.add_child(inst)

	_runner = inst.find_child(ModelCatalog.turbine_node_for(MODEL_ID), true, false) as Node3D
	if _runner == null:
		_runner = inst.find_child("Pelton Wheel*", true, false) as Node3D
	# The housing is DERIVED, not looked up by name: every MeshInstance3D that is
	# not part of the runner. A name lookup ("model.skp") is one exporter quirk
	# away from silently matching nothing, and the failure mode is a solid black
	# box with the camera inside it rather than an error.
	_housing_meshes.clear()
	for n: Node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if _runner != null and (mi == _runner or _runner.is_ancestor_of(mi)):
			continue
		_housing_meshes.append(mi)
	if _runner != null:
		_runner_rest = _runner.transform
		_measure_runner()
	else:
		# No runner resolved — frame the whole model so the tab still shows the
		# machine instead of an empty studio.
		_runner_centre = _model_aabb().get_center()
		_runner_radius = maxf(_model_aabb().size.length() * 0.25, 0.05)
	_measure_inlet_port(inst)
	print("HydroTurbineCloseup: runner=%s radius=%.3f m centre=%s housing meshes=%d port_dy=%.3f m" % [
		"yes" if _runner != null else "NO", _runner_radius, str(_runner_centre),
		_housing_meshes.size(), _port_dy])


## Height of the machine's REAL penstock inlet (`res_in_0`) relative to the runner
## centre, in _model_root space.
##
## Prefers the player's own saved port layout — if they moved the inlet in the
## Connection Ports modal, the pipe in 3D attaches THERE and the close-up has to
## agree. Port positions are authored in the GLB's unit space, so they go through
## the same instance transform the runner did.
func _measure_inlet_port(inst: Node3D) -> void:
	_port_dy = 0.0
	# load_catalog_ports prefers the player's saved layout and falls back to the
	# built-in defaults — the same resolution the 3D conduit uses.
	var ports: Array = ConnectionPortDefs.load_catalog_ports(MODEL_ID)
	for p_v: Variant in ports:
		var p: Dictionary = p_v as Dictionary
		if str(p.get("handle_id", "")) != "res_in_0":
			continue
		# Port positions are stored as flat x/y/z scalars, not a "pos" Vector3 —
		# a `get("pos", Vector3.ZERO)` silently measures the model ORIGIN instead
		# and reports a perfectly plausible-looking 0.000 m offset.
		var local := Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)),
				float(p.get("z", 0.0)))
		_port_dy = (inst.transform * local).y - _runner_centre.y
		return


## AABB of the whole instantiated model in _model_root space.
func _model_aabb() -> AABB:
	var out := AABB()
	var first := true
	for n: Node in _model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var a := _local_chain(mi, _model_root) * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


## Runner geometry, measured rather than hardcoded so a re-export keeps working.
## The catalog records the spin axis (model-local X for the PowerSpout); the
## centre and radius come from the mesh AABB composed up to ModelRoot, using LOCAL
## transforms because global_transform can be stale in a deferred build.
func _measure_runner() -> void:
	var axis_key := ModelCatalog.spin_axis_for(MODEL_ID)
	match axis_key:
		"x": _runner_axis_local = Vector3.RIGHT
		"y": _runner_axis_local = Vector3.UP
		_: _runner_axis_local = Vector3.BACK
	var mi: MeshInstance3D = _first_mesh(_runner)
	if mi == null:
		return
	var aabb := mi.get_aabb()
	var xf := _local_chain(mi, _model_root)
	_runner_centre = xf * aabb.get_center()
	# `_runner.transform` is LOCAL to the runner's PARENT, and the GLB carries
	# intermediate nodes (including one with a baked inch->metre scale) between
	# ModelRoot and the wheel. Rotating about a ModelRoot-space centre in that
	# local frame throws the wheel clean out of the housing — it renders, it is
	# just nowhere near where it belongs, which reads as "the runner is missing".
	# So the SPIN centre is measured in the parent frame, while the camera, jet
	# and splash keep the ModelRoot-space one.
	_runner_centre_parent = _local_chain(mi, _runner.get_parent()) * aabb.get_center()
	# Radius = half the LARGEST extent perpendicular to the axis (a Pelton disc is
	# flat along its axis, so the two big extents are the disc face).
	var ext := (xf.basis * aabb.size).abs()
	var comps := [ext.x, ext.y, ext.z]
	comps.sort()
	_runner_radius = maxf(float(comps[2]) * 0.5, 0.02)
	# Tailwater leaves at the bottom of the machine, under the wheel.
	var whole := _model_aabb()
	_housing_bottom = Vector3(_runner_centre.x, whole.position.y, _runner_centre.z)


func _first_mesh(root: Node) -> MeshInstance3D:
	if root == null:
		return null
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		return n as MeshInstance3D
	return null


## Compose LOCAL transforms from `node` up to (but excluding) `stop`.
func _local_chain(node: Node3D, stop: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != stop:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


# ---------------------------------------------------------------------------
# Water
# ---------------------------------------------------------------------------

func _build_water() -> void:
	if _model_root == null:
		return
	_jet = _make_jet()
	_jet_mat = _jet.material_override as ShaderMaterial
	_studio.add_child(_jet)
	_jet2 = _make_jet()
	_jet2_mat = _jet2.material_override as ShaderMaterial
	_jet2.visible = false
	_studio.add_child(_jet2)
	# The nozzle the jet comes OUT of. Without it the water starts in mid-air,
	# which reads as a floating rod rather than as plumbing — and the GLB has no
	# modeled nozzle to borrow (three meshes: runner, housing, a bracket plate).
	_nozzle = _make_nozzle()
	_studio.add_child(_nozzle)
	_nozzle2 = _make_nozzle()
	_nozzle2.visible = false
	_studio.add_child(_nozzle2)

	# Splash-back at the bucket: the jet shatters off the spoon edge and fans
	# roughly back along itself.
	_splash = _make_spray(0.005, 0.22, SPLASH_MAX)
	_splash_mat = _splash.process_material as ParticleProcessMaterial
	_splash_mat.spread = 55.0
	_studio.add_child(_splash)

	# Tailwater out the bottom of the housing. Its own emitter rather than
	# ConduitDischargeVfx: that class is tuned for a culvert bank running tens of
	# L/s, and every one of its droplet numbers would need overriding for a
	# 0.28 m runner dribbling ~1 L/s — at which point nothing of it is reused but
	# the shape of the code, and the culvert stays safely untouched.
	_tailwater = _make_spray(0.006, 0.30, 120)
	_tailwater_mat = _tailwater.process_material as ParticleProcessMaterial
	_tailwater_mat.direction = Vector3.DOWN
	_tailwater_mat.spread = 18.0
	_studio.add_child(_tailwater)


## A water-spray emitter sized in ABSOLUTE metres. `drop_m` is the droplet's
## on-screen size — a Pelton's spray is millimetres against a 0.28 m wheel, so the
## quad carries the size and scale_min/max stay at 1.0 rather than compounding two
## multipliers whose product is impossible to reason about.
func _make_spray(drop_m: float, life_s: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.amount_ratio = 0.0
	p.lifetime = life_s
	p.emitting = false
	# World-space so the arc keeps falling under real gravity regardless of how
	# the emitter is oriented.
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = drop_m * 1.5
	m.gravity = Vector3(0, -9.8, 0)
	m.scale_min = 1.0
	m.scale_max = 1.0
	p.process_material = m
	var q := QuadMesh.new()
	q.size = Vector2(drop_m, drop_m)
	var qm := StandardMaterial3D.new()
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.albedo_color = Color(0.80, 0.92, 1.0, 0.85)
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = qm
	p.draw_pass_1 = q
	return p


## A Pelton nozzle: a short tapered spear housing narrowing to the jet bore, on a
## stub of the manifold it hangs off. One node with two children so the whole
## assembly can be aimed with a single transform, and so its LENGTH stays fixed
## while the jet's varies with the runner radius.
func _make_nozzle() -> Node3D:
	var root := Node3D.new()
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.30, 0.32, 0.36)
	steel.metallic = 0.85
	steel.roughness = 0.35
	# Taper: manifold bore down to the jet bore. Local +Y points DOWN the jet, so
	# the narrow end is at +Y (top of a CylinderMesh).
	var tip := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = NOZZLE_TIP_R
	cone.bottom_radius = NOZZLE_BODY_R
	cone.height = NOZZLE_LEN_M
	cone.radial_segments = 12
	cone.rings = 1
	tip.mesh = cone
	tip.material_override = steel
	tip.position = Vector3(0, NOZZLE_LEN_M * 0.5, 0)
	root.add_child(tip)
	# Manifold stub behind it, so the nozzle is fed by something.
	var stub := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = NOZZLE_BODY_R
	cyl.bottom_radius = NOZZLE_BODY_R * 1.15
	cyl.height = NOZZLE_STUB_M
	cyl.radial_segments = 12
	cyl.rings = 1
	stub.mesh = cyl
	stub.material_override = steel
	stub.position = Vector3(0, -NOZZLE_STUB_M * 0.5, 0)
	root.add_child(stub)
	return root


func _make_jet() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005
	cyl.bottom_radius = 0.005
	cyl.height = 1.0
	cyl.radial_segments = 10
	cyl.rings = 1
	mi.mesh = cyl
	var sm := ShaderMaterial.new()
	sm.shader = load("res://core/conduits/pelton_jet.gdshader")
	mi.material_override = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _free_particles() -> void:
	if _splash != null:
		_splash.emitting = false
	if _tailwater != null:
		_tailwater.emitting = false


# ---------------------------------------------------------------------------
# Public API (called BY STRING from the Lab — keep the surface stable)
# ---------------------------------------------------------------------------

func setup(_graph_view: Node) -> void:
	pass


func set_turbine(_item_id: String) -> void:
	pass


## {q_lps, h_net_m, v_jet_ms, rpm, speed_ratio, nozzle_d_m, nozzle_n,
##  runner_pcd_m, load_frac, eta_runner}
func set_state(s: Dictionary) -> void:
	_state = s


func set_display_mode(mode: String) -> void:
	_apply_display_mode(mode)


## Player fine-tune (metres) on the nozzle height, over the measured port.
func set_nozzle_offset_m(v: float) -> void:
	_nozzle_offset_m = v


func _apply_display_mode(mode: String) -> void:
	_display_mode = mode
	for mi: MeshInstance3D in _housing_meshes:
		if not is_instance_valid(mi):
			continue
		mi.visible = mode != "runner"
		mi.material_override = _ghost_mat if mode == "cutaway" else null
	for b: Button in _mode_btns:
		if is_instance_valid(b):
			b.set_pressed_no_signal(str(b.get_meta("mode", "")) == mode)


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active or not _built or _runner == null:
		return
	_t += delta
	var v_jet := float(_state.get("v_jet_ms", 0.0))
	var q_lps := float(_state.get("q_lps", 0.0))
	var pcd := maxf(float(_state.get("runner_pcd_m", 0.28)), 0.02)
	var load_frac := clampf(float(_state.get("load_frac", 1.0)), 0.0, 1.0)
	var x := PeltonPhysics.speed_ratio_for_load(load_frac)
	var target_omega := 0.0
	_true_rpm = 0.0
	if q_lps > 0.001 and v_jet > 0.01:
		var true_omega := PeltonPhysics.omega_rad_s_at_ratio(v_jet, pcd, x)
		_true_rpm = true_omega * 60.0 / TAU
		target_omega = _display_omega(true_omega)
	# A shed load ACCELERATES the wheel slowly (inertia); loading it slows faster.
	var tau := TAU_SHED_S if target_omega > _omega else TAU_LOAD_S
	_omega = lerpf(_omega, target_omega, clampf(1.0 - exp(-delta / tau), 0.0, 1.0))
	if absf(_omega) > 0.02:
		_angle = wrapf(_angle + _omega * delta, -TAU, TAU)
		var rot := Basis(_runner_axis_local.normalized(), _angle)
		_runner.transform = Transform3D(rot,
				_runner_centre_parent - rot * _runner_centre_parent) * _runner_rest
	_update_water(delta, q_lps, v_jet)
	_update_hud(v_jet, x, q_lps)
	_apply_camera()


## Compress the TRUE shaft speed into one the eye can actually read.
##
## A 24-bucket runner at 458 rpm passes 183 buckets per second. Sampled at 60 fps
## that aliases hard — the classic wagon-wheel effect — and the wheel appears to
## crawl or stand still while only the arms register, which is exactly the "it
## spins so fast it looks slow" report. No frame rate fixes this: the signal is
## above Nyquist for the bucket count.
##
## So the DISPLAYED rate saturates smoothly toward DISPLAY_RPM_MAX. The mapping is
## monotonic, so faster is always visibly faster and the matched-vs-runaway
## difference still reads; it is simply compressed. The HUD keeps reporting the
## TRUE rpm — the number is honest, only the animation is legible.
func _display_omega(true_omega: float) -> float:
	if true_omega <= 0.0:
		return 0.0
	var true_rpm := true_omega * 60.0 / TAU
	var shown := DISPLAY_RPM_MAX * (1.0 - exp(-true_rpm / DISPLAY_RPM_KNEE))
	return shown * TAU / 60.0


func _update_water(delta: float, q_lps: float, v_jet: float) -> void:
	if _jet == null:
		return
	var n := maxi(int(_state.get("nozzle_n", 1)), 1)
	var noz_d := maxf(float(_state.get("nozzle_d_m", 0.010)), 0.001)
	var flowing := q_lps > 0.001 and v_jet > 0.01
	var intensity := clampf(q_lps / 2.0, 0.0, 1.0) if flowing else 0.0
	# The jet must arrive IN THE PLANE OF THE WHEEL — perpendicular to the runner
	# axis — or it runs straight down the view direction and is invisible end-on.
	var side := _jet_side()
	_seat_jet(_jet, _jet_mat, side, noz_d, v_jet, intensity)
	_seat_nozzle(_nozzle, side)
	_jet2.visible = n >= 2 and flowing
	_nozzle2.visible = n >= 2
	if _jet2.visible:
		_seat_jet(_jet2, _jet2_mat, -side, noz_d, v_jet, intensity)
	if _nozzle2.visible:
		_seat_nozzle(_nozzle2, -side)

	if _splash != null:
		_splash.emitting = flowing
		_splash.amount_ratio = lerpf(0.25, 1.0, intensity)
		if flowing:
			_splash.global_position = _impact_point(side)
			# Fan back along the jet, biased up across the wheel face.
			_splash_mat.direction = (side + Vector3(0, 0.35, 0)).normalized()
			# Exit speed is the BUCKET RELATION, not a fudged fraction of the jet:
			# at the matched load nearly all the jet's momentum has gone into the
			# shaft, so the water barely leaves — which is why a well-tuned Pelton
			# dribbles. Shed the load and it sprays. Capped because a runaway's
			# ~14 m/s would clear the frame in two frames.
			var v_exit := PeltonPhysics.bucket_exit_speed_ms(v_jet,
					PeltonPhysics.speed_ratio_for_load(
						clampf(float(_state.get("load_frac", 1.0)), 0.0, 1.0)))
			_splash_mat.initial_velocity_min = clampf(v_exit * 0.45, 0.10, 2.0)
			_splash_mat.initial_velocity_max = clampf(v_exit * 1.10, 0.25, 4.5)
	if _tailwater != null:
		_tailwater.emitting = flowing
		_tailwater.amount_ratio = lerpf(0.3, 1.0, intensity)
		if flowing:
			_tailwater.global_position = _housing_bottom
			_tailwater_mat.initial_velocity_min = lerpf(0.10, 0.35, intensity)
			_tailwater_mat.initial_velocity_max = lerpf(0.25, 0.70, intensity)


## A unit direction lying IN the wheel's plane (perpendicular to the spin axis),
## preferring a horizontal one — a PowerSpout's nozzle enters from the side, and a
## side-on camera looks ALONG the axis, so an in-plane jet is the only one visible.
func _jet_side() -> Vector3:
	var axis := _runner_axis_local.normalized()
	var s := axis.cross(Vector3.UP)
	if s.length_squared() < 1e-5:
		s = axis.cross(Vector3.BACK)
	return s.normalized()


## Height of the jet line RELATIVE to the runner centre.
##
## The nozzle used to sit at the runner's centre height, which put it a couple of
## inches above the machine's real `res_in_0` penstock inlet — the port a player
## can see in 3D and has wired a pipe to. The port is the truth, so the jet is
## measured from it; `_nozzle_offset_m` is the player's fine-tune on top.
func _jet_dy() -> float:
	return _port_dy + _nozzle_offset_m


## Where the jet strikes the pitch circle, at the jet's own height.
##
## A horizontal jet entering at height dy meets the pitch circle at
## x = sqrt(r² − dy²), NOT at the 3 o'clock point — which is also why a real
## PowerSpout's nozzle aims into the lower part of the wheel rather than its
## equator. Degenerate (|dy| >= r) falls back to a shallow tangent.
func _impact_point(side: Vector3) -> Vector3:
	var dy := _jet_dy()
	var span := _runner_radius * _runner_radius - dy * dy
	var x := sqrt(span) if span > 1e-6 else _runner_radius * 0.15
	return _runner_centre + side.normalized() * x + Vector3.UP * dy


## Park the nozzle so its TIP is exactly the jet's mouth and its bore points down
## the jet. Unlike the jet it does not stretch — a nozzle is a fixed object.
func _seat_nozzle(root: Node3D, side: Vector3) -> void:
	if root == null:
		return
	var mouth := _jet_mouth(side)
	var dir := (_impact_point(side) - mouth).normalized()
	root.transform = Transform3D(_basis_along(dir), mouth - dir * NOZZLE_LEN_M)


## Where the jet leaves the nozzle, on the given side of the runner — outboard of
## the impact point along the same horizontal line, so nozzle and jet are colinear.
func _jet_mouth(side: Vector3) -> Vector3:
	return _runner_centre + side.normalized() * (_runner_radius * 2.1) \
			+ Vector3.UP * _jet_dy()


## An orthonormal basis whose local +Y runs along `dir` (CylinderMesh's own axis).
func _basis_along(dir: Vector3) -> Basis:
	var up := dir.normalized()
	var fwd := up.cross(Vector3.UP)
	if fwd.length_squared() < 1e-5:
		fwd = up.cross(Vector3.BACK)
	fwd = fwd.normalized()
	return Basis(up.cross(fwd).normalized(), up, fwd)


func _seat_jet(mi: MeshInstance3D, mat: ShaderMaterial, side: Vector3,
		noz_d: float, v_jet: float, intensity: float) -> void:
	if mi == null or mat == null:
		return
	mi.visible = intensity > 0.001
	if not mi.visible:
		return
	var hit := _impact_point(side)
	var mouth := _jet_mouth(side)
	var len_m := maxf(mouth.distance_to(hit), 0.01)
	var mid := (mouth + hit) * 0.5
	# CylinderMesh runs along local Y — aim it down the jet.
	mi.transform = Transform3D(_basis_along(hit - mouth), mid)
	mi.scale = Vector3(maxf(noz_d, 0.002) / 0.01, len_m, maxf(noz_d, 0.002) / 0.01)
	mat.set_shader_parameter("speed_ms", v_jet)
	mat.set_shader_parameter("jet_len_m", len_m)
	mat.set_shader_parameter("t", _t)
	mat.set_shader_parameter("intensity", intensity)


func _update_hud(v_jet: float, x: float, q_lps: float) -> void:
	if _hud == null:
		return
	# `runner_efficiency(x, 1.0)` is the FRACTION of the matched-load output the
	# runner delivers at this speed ratio — it is 1.0 at x_opt by construction, so
	# the graph's power (which assumes a matched load, as a real dump-load or MPPT
	# controller enforces) scales straight through it. Without this the HUD read
	# "η_runner 0%" at runaway while the status strip a few pixels below reported
	# full watts, which is two numbers on one screen contradicting each other.
	var frac := PeltonPhysics.runner_efficiency(x, 1.0)
	var w := float(_state.get("power_w", 0.0)) * frac
	# TRUE rpm, not the compressed display rate (_display_omega) — the animation
	# is slowed to stay legible, the number must not be.
	# Say WHICH machine state this is. At 100% load it equals the Lab's other two
	# readouts exactly; below that it is deliberately lower, and without the label
	# that difference reads as three panels disagreeing.
	var load_pct := clampf(float(_state.get("load_frac", 1.0)), 0.0, 1.0) * 100.0
	var tag := "at matched load" if load_pct > 99.5 else "at %.0f%% load" % load_pct
	_hud.text = "%s — v_jet %.1f m/s · x %.2f · %.0f rpm · %.0f W (%.0f%% of matched) · Q %.2f L/s" % [
		tag, v_jet, x, _true_rpm, w, frac * 100.0, q_lps]


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

## Side-on: the runner axis is model-local X, so "the wheel as a disc with the jet
## hitting a bucket tangentially" means looking ALONG that axis at the centre.
func _frame_camera() -> void:
	# Far enough back that the wheel fills a comfortable share of the frame, and —
	# the part that matters — always OUTSIDE the housing shell, whose extent along
	# the view axis is unknown until the model is measured.
	# The frame height at distance d is 2·d·tan(fov/2); size it so the WHOLE
	# machine fits with margin, then never closer than clear of the shell.
	var shell := _model_aabb()
	var span := maxf(shell.size.x, maxf(shell.size.y, shell.size.z))
	var fit := (span * 1.45) / (2.0 * tan(deg_to_rad(_camera.fov * 0.5)))
	_dist = clampf(maxf(fit, span * 0.9), DIST_MIN, DIST_MAX)
	_orbit_yaw = 0.0
	_orbit_pitch = -6.0
	_apply_camera()


func _apply_camera() -> void:
	if _camera == null:
		return
	var basis := Basis(Vector3.UP, deg_to_rad(_orbit_yaw)) \
			* Basis(Vector3.RIGHT, deg_to_rad(_orbit_pitch))
	var eye := _runner_centre + basis * (_runner_axis_local.normalized() * _dist)
	_camera.global_position = eye
	_camera.look_at(_runner_centre, Vector3.UP)


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = clampf(_dist / 1.12, DIST_MIN, DIST_MAX)
			_apply_camera()
			_container.accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = clampf(_dist * 1.12, DIST_MIN, DIST_MAX)
			_apply_camera()
			_container.accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_last_mouse = mb.position
			_container.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var d := mm.position - _last_mouse
		_last_mouse = mm.position
		# Clamped so the side-on read — the reason this view exists — is never lost.
		_orbit_yaw = clampf(_orbit_yaw - d.x * 0.35, -ORBIT_LIMIT_DEG, ORBIT_LIMIT_DEG)
		_orbit_pitch = clampf(_orbit_pitch - d.y * 0.35, -ORBIT_LIMIT_DEG, ORBIT_LIMIT_DEG)
		_apply_camera()
		_container.accept_event()

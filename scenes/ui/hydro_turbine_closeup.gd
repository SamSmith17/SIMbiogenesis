extends Control

## Hydro Lab "Turbine close-up": the turbine the graph item WEARS (PowerSpout
## PLT, the AliExpress micro Pelton — whatever HydroSource.KINDS.model_id says)
## seen along its shaft with its housing ghosted away, the real runner spinning
## at a speed derived from the jet and the electrical LOAD, a coherent water jet
## from the nozzle to the buckets, the water LEAVING the buckets as two sheets
## whose direction and speed are the bucket relation, splash mist where it
## strikes, and tailwater falling out the bottom.
##
## Why the machine reads honestly:
##  - the runner is the GLB's own node (catalog `turbine_node`), spun about the
##    axis the catalog records, exactly as SiphonTurbineSpin does in the world;
##  - the nozzle is the GLB's own fitting when it has one (catalog
##    `nozzle_node`: the micro Pelton's hose barb through the housing wall);
##    otherwise a procedural spear nozzle hung off the real `res_in_0` port;
##  - the jet's scroll rate is PeltonPhysics.jet_velocity_ms(h_net) — more head
##    really does make a visibly faster jet;
##  - shaft speed is PeltonPhysics.omega_rad_s_at_ratio(v_jet, PCD, x) where x
##    comes from speed_ratio_for_load, so shedding the load runs the wheel away
##    toward 2·x_opt while runner_efficiency collapses to zero;
##  - the exit sheets are PeltonPhysics.bucket_exit_velocity: the relative flow
##    turned through the bucket's ~165°, plus the bucket's own speed. At the
##    matched load that is a slow, slightly backward, mostly SIDEWAYS dribble;
##    stalled, the jet bounces straight back; at runaway it is carried round.
##
## The player positions the jet (the Lab's "Nozzle placement" row): where on
## the rim the nozzle sits, how far off the pitch line it aims, how far along
## the shaft (the splitter vs one side of the bucket), two tilts and a
## standoff. The JET'S-EYE camera looks down the jet from the mouth at the
## landing ring on the cups, which is how you see where it hits.
##
## Studio pattern is the canonical in-modal one (linkage_hardware_modal): a
## SubViewportContainer over an own_world_3d SubViewport with a three-point rig.
## Deliberately NOT graph_soi_preview_service — that service carries the AMD-TDR
## crop/clamp scar tissue and a shared World3D; an own_world_3d studio does not.

const DEFAULT_MODEL_ID := "powerspout_plt"
## Long-edge cap, well under the section service's 1280 px TDR ceiling.
const VIEWPORT_LONG_PX := 1024
const ORBIT_LIMIT_DEG := 35.0
const JET_ORBIT_LIMIT_DEG := 22.0
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
const SPLASH_MAX := 120
const SHEET_MAX := 220
## Nozzle body (metres). A PowerSpout's spear nozzle is a stubby thing — the
## length is fixed while the JET's length follows the runner radius, so the two
## must not share a scale.
const NOZZLE_LEN_M := 0.055
const NOZZLE_TIP_R := 0.011
const NOZZLE_BODY_R := 0.024
const NOZZLE_STUB_M := 0.05
## Jet's-eye camera: how far behind the mouth and how far off the jet line the
## eye sits, and its narrower field. The first cut put the eye 35 mm back and
## 15 mm up: the rod's end cap 3 cm in front of the lens filled the frame as
## one cyan octagon and the arrows loomed — the eye has to stand clear of
## the water, looking down ONTO the jet at the landing ring.
const JET_EYE_BACK_M := 0.075
const JET_EYE_LIFT_MIN_M := 0.032
const JET_EYE_LIFT_FRAC := 3.0
const JET_EYE_FOV := 34.0
const SIDE_FOV := 42.0

var _viewport: SubViewport
var _container: SubViewportContainer
var _studio: Node3D
var _camera: Camera3D
var _model_root: Node3D
var _model_id := DEFAULT_MODEL_ID
var _runner: Node3D
## Every mesh that is NOT the runner — derived, not name-matched (see _build_model).
var _housing_meshes: Array[MeshInstance3D] = []
## The modelled nozzle fitting's meshes (hidden in the jet's-eye view, where
## the eye sits inside them).
var _nozzle_meshes: Array[MeshInstance3D] = []
var _hud: Label

var _jet: MeshInstance3D
var _jet_mat: ShaderMaterial
var _jet2: MeshInstance3D
var _jet2_mat: ShaderMaterial
var _nozzle: Node3D
var _nozzle2: Node3D
var _splash: GPUParticles3D
var _splash_mat: ParticleProcessMaterial
## The two exit sheets off the bucket splitter (±axis), one pair per jet.
var _sheets: Array[GPUParticles3D] = []
var _sheet_mats: Array[ParticleProcessMaterial] = []
var _tailwater: GPUParticles3D
var _tailwater_mat: ParticleProcessMaterial
## Landing ring on the cups + the velocity arrows (jet / bucket / exits).
var _marker: MeshInstance3D
var _arrows: Dictionary = {}

var _ghost_mat: StandardMaterial3D
var _mode_btns: Array[Button] = []
var _cam_btns: Array[Button] = []
var _vec_btn: Button
## In-viewport chrome: the view hint (top-left) and the vector legend.
var _overlay_hint: Label
var _legend: HBoxContainer
var _display_mode := "cutaway"
var _cam_mode := "side"
var _show_vectors := false

## Live state pushed by the Lab (set_state).
var _state: Dictionary = {}
## SIPHON mode (the Lab's turbine kind "siphon"): no jet — the machine is a
## propeller in a pipe with the pond's surface somewhere above or below it.
## The view shows the water column in the housing, the pond's waterline
## relative to the turbine, the dip tube hanging into it, the draft tube
## leaving below, and the flow through all of it as beads riding the path
## at the draft velocity. Built lazily the first time a siphon state arrives.
var _siphon := false
var _s_built := false
var _s_waterline: MeshInstance3D = null
var _s_column: MeshInstance3D = null
var _s_leg: MeshInstance3D = null
var _s_dip: MeshInstance3D = null
var _s_draft: MeshInstance3D = null
var _s_beads: Array[MeshInstance3D] = []
var _s_path := PackedVector3Array()
var _s_phase := 0.0
var _s_rpm_true := 0.0
const S_BEADS := 28
const S_BEAD_R := 0.007
const S_FLOW_MAX_MPS := 0.55   ## display speed cap along the path (studio m/s)
var _omega := 0.0        ## DISPLAY rate (compressed) — what the mesh turns at
var _true_rpm := 0.0     ## physical shaft speed — what the HUD reports
var _angle := 0.0
var _t := 0.0
var _built := false
var _active := false
## What the last frame computed — read by the harness (debug_summary).
var _last: Dictionary = {}

## Measured once from the instantiated model.
var _runner_axis_local := Vector3(1, 0, 0)
var _runner_centre := Vector3.ZERO
## Same point expressed in the runner's PARENT frame — the only space in which
## `_runner.transform` may be rotated about it (see _measure_runner).
var _runner_centre_parent := Vector3.ZERO
## The spin axis in the runner's PARENT frame — the frame `_runner.transform`
## lives in. `_runner_axis_local` is the catalog's axis in MODEL-ROOT space
## (what the camera, jet and splash use), and the GLB can carry a rotation
## between ModelRoot and the wheel: the micro Pelton's top node is turned
## −90° about X, so model-root +Y is parent +Z. Rotating about parent +Y put
## the axis IN the disc's plane and the wheel tumbled like a coin on a table.
var _runner_axis_parent := Vector3(0, 0, 1)
## The disc's own normal (its thinnest mesh extent) in the parent frame — the
## measured truth the catalog axis is checked against.
var _disc_normal_parent := Vector3(0, 0, 1)
var _runner_radius := 0.14
var _runner_thickness := 0.06
var _runner_rest := Transform3D.IDENTITY
var _housing_bottom := Vector3.ZERO
## Height of the real `res_in_0` inlet port relative to the runner centre (m) —
## the procedural nozzle's base line when the GLB has no fitting.
var _port_dy := 0.0
## The GLB's own nozzle fitting: mouth + direction in _model_root space, or a
## zero direction when the model has none.
var _noz_base_mouth := Vector3.ZERO
var _noz_base_dir := Vector3.ZERO
## Player's nozzle placement (the Lab's row), metres / degrees.
var _noz := {"offset_m": 0.0, "axial_m": 0.0, "angle_deg": 0.0,
	"tilt_in_deg": 0.0, "tilt_out_deg": 0.0, "standoff_m": 0.0}

var _orbit_yaw := 0.0
var _orbit_pitch := -6.0
var _dist := 0.55
var _jet_yaw := 0.0
var _jet_pitch := 0.0
var _jet_dolly := 1.0
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
	_camera.near = 0.005
	_camera.far = 50.0
	_camera.fov = SIDE_FOV
	_studio.add_child(_camera)

	# In-viewport chrome: a view hint top-left and, under it, the vector legend.
	var ov := VBoxContainer.new()
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ov.position = Vector2(UITheme.SPACE_SM, UITheme.SPACE_SM)
	ov.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_container.add_child(ov)
	_overlay_hint = Label.new()
	_overlay_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_hint.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_overlay_hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_overlay_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_overlay_hint.add_theme_constant_override("shadow_offset_x", 1)
	_overlay_hint.add_theme_constant_override("shadow_offset_y", 1)
	ov.add_child(_overlay_hint)
	_legend = HBoxContainer.new()
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_legend.visible = false
	ov.add_child(_legend)
	for spec: Array in [["jet", Color(0.45, 0.92, 1.0)], ["bucket", Color(1.0, 0.72, 0.25)],
			["leaving the cup", Color(0.55, 0.70, 1.0)], ["landing", Color(0.35, 1.0, 0.95)]]:
		_legend.add_child(_legend_chip(str(spec[0]), spec[1] as Color))

	# Footer: the readout on the left, the controls in three labelled groups.
	var foot_panel := PanelContainer.new()
	foot_panel.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_PANEL))
	vbox.add_child(foot_panel)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", UITheme.SPACE_SM)
	foot_panel.add_child(foot)
	_hud = Label.new()
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hud.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.add_theme_font_size_override("font_size", UITheme.FONT_XS + 1)
	_hud.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_hud.text = "—"
	foot.add_child(_hud)
	# Where the camera stands. Side = along the shaft (the wheel as a disc);
	# Jet's eye = from the nozzle mouth down the jet, at the landing ring —
	# the only view that answers "where on the cups does it hit".
	_cam_btns.clear()
	var cam_group := _footer_group(foot, "View")
	for spec: Array in [["Side", "side", "Along the shaft: the wheel as a disc, the jet tangential."],
			["Jet's eye", "jet", "From the nozzle, down the jet, at the spot where it lands on the cups."]]:
		var cmode := str(spec[1])
		var cb := _footer_toggle(cam_group, str(spec[0]), str(spec[2]), cmode,
				func() -> void: set_camera_mode(cmode))
		_cam_btns.append(cb)
	# How much machine to show. Cutaway is the default because it is the reason
	# this view exists, but a Pelton bucket's shape is worth seeing bare, and the
	# intact housing is what the player actually placed in the world.
	_mode_btns.clear()
	var show_group := _footer_group(foot, "Show")
	for spec: Array in [["Housing", "housing", "The machine as it stands in the world."],
			["Cutaway", "cutaway", "Housing ghosted so the runner and jet are visible."],
			["Runner", "runner", "Housing hidden entirely — just the wheel and the jet."]]:
		var mode := str(spec[1])
		var b := _footer_toggle(show_group, str(spec[0]), str(spec[2]), mode,
				func() -> void: set_display_mode(mode))
		_mode_btns.append(b)
	var vec_group := _footer_group(foot, "Overlay")
	_vec_btn = _footer_toggle(vec_group, "Vectors",
			"Draw the velocities: the jet (cyan), the bucket's own speed (amber) "
			+ "and the water leaving each half of the splitter (blue). Lengths scale with speed.",
			"vectors", func() -> void: set_vectors(_vec_btn.button_pressed))

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
	_apply_camera_mode("side")
	_frame_camera()


func _add_light(rot_deg: Vector3, energy: float) -> void:
	var l := DirectionalLight3D.new()
	l.rotation_degrees = rot_deg
	l.light_energy = energy
	l.shadow_enabled = false
	_studio.add_child(l)


## A captioned group of toggles in the footer ("View  [Side][Jet's eye]").
func _footer_group(foot: Control, caption: String) -> HBoxContainer:
	var g := HBoxContainer.new()
	g.add_theme_constant_override("separation", 2)
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var cap := Label.new()
	cap.text = caption
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	g.add_child(cap)
	var pad := Control.new()
	pad.custom_minimum_size.x = UITheme.SPACE_XS
	g.add_child(pad)
	foot.add_child(g)
	return g


func _footer_toggle(group: Control, text: String, tip: String, mode: String,
		on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.set_meta("mode", mode)
	b.pressed.connect(on_press)
	UITheme.style_toggle(b, false, UITheme.FONT_XS + 1)
	group.add_child(b)
	return b


func _legend_chip(text: String, col: Color) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UITheme.chip_style(col))
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", col.lightened(0.25))
	p.add_child(l)
	return p


## The toggle faces follow the state, not the click (the harness and the Lab
## drive these by call, never through the buttons).
func _restyle_buttons() -> void:
	for b: Button in _mode_btns:
		if is_instance_valid(b):
			var on := str(b.get_meta("mode", "")) == _display_mode
			b.set_pressed_no_signal(on)
			UITheme.style_toggle(b, on, UITheme.FONT_XS + 1)
	for cb: Button in _cam_btns:
		if is_instance_valid(cb):
			var on2 := str(cb.get_meta("mode", "")) == _cam_mode
			cb.set_pressed_no_signal(on2)
			UITheme.style_toggle(cb, on2, UITheme.FONT_XS + 1)
	if _vec_btn != null:
		_vec_btn.set_pressed_no_signal(_show_vectors)
		UITheme.style_toggle(_vec_btn, _show_vectors, UITheme.FONT_XS + 1)
	if _legend != null:
		_legend.visible = _show_vectors or _cam_mode == "jet"
	if _overlay_hint != null:
		_overlay_hint.text = ("Jet's eye — looking down the jet at the cups · the ring is where it lands · drag to nudge · wheel to dolly"
				if _cam_mode == "jet" else
				"Side — along the shaft · drag to orbit · wheel to zoom")


func _build_model() -> void:
	var inst: Node3D = ModelCatalog.instantiate(_model_id)
	if inst == null:
		return
	_model_root = Node3D.new()
	_model_root.name = "ModelRoot"
	_studio.add_child(_model_root)
	inst.scale = Vector3.ONE * ModelCatalog.resolved_scale(_model_id, 1.0)
	_model_root.add_child(inst)

	_runner = inst.find_child(ModelCatalog.turbine_node_for(_model_id), true, false) as Node3D
	if _runner == null:
		_runner = inst.find_child("Pelton Wheel*", true, false) as Node3D
	# The housing is DERIVED, not looked up by name: every MeshInstance3D that is
	# not part of the runner. A name lookup ("model.skp") is one exporter quirk
	# away from silently matching nothing, and the failure mode is a solid black
	# box with the camera inside it rather than an error.
	_housing_meshes.clear()
	_nozzle_meshes.clear()
	var noz_name := ModelCatalog.nozzle_node_for(_model_id)
	var noz_node: Node = inst.find_child(noz_name, true, false) if not noz_name.is_empty() else null
	for n: Node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if _runner != null and (mi == _runner or _runner.is_ancestor_of(mi)):
			continue
		_housing_meshes.append(mi)
		if noz_node != null and (mi == noz_node or noz_node.is_ancestor_of(mi)):
			_nozzle_meshes.append(mi)
	if _runner != null:
		_runner_rest = _runner.transform
		_measure_runner()
	else:
		# No runner resolved — frame the whole model so the tab still shows the
		# machine instead of an empty studio.
		_runner_centre = _model_aabb().get_center()
		_runner_radius = maxf(_model_aabb().size.length() * 0.25, 0.05)
	_measure_inlet_port(inst)
	_measure_nozzle_base(noz_node as Node3D)
	_omega = 0.0
	_angle = 0.0
	print("HydroTurbineCloseup: model=%s runner=%s radius=%.3f m axis=%s centre=%s housing meshes=%d port_dy=%.3f m nozzle=%s" % [
		_model_id, "yes" if _runner != null else "NO", _runner_radius, str(_runner_axis_local),
		str(_runner_centre), _housing_meshes.size(), _port_dy,
		("fitting @ %s -> %s" % [str(_noz_base_mouth), str(_noz_base_dir)]) if _has_modelled_nozzle() else "procedural"])


## Swap the machine for another catalog model (the Lab's turbine kind changed).
## Water, camera rig and HUD are studio-level and survive; everything measured
## off the model is re-measured.
func _rebuild_model() -> void:
	if _model_root != null and is_instance_valid(_model_root):
		_model_root.queue_free()
	_model_root = null
	_runner = null
	_housing_meshes.clear()
	_nozzle_meshes.clear()
	_noz_base_dir = Vector3.ZERO
	_build_model()
	_apply_display_mode(_display_mode)
	_apply_camera_mode(_cam_mode)
	_frame_camera()


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
	var ports: Array = ConnectionPortDefs.load_catalog_ports(_model_id)
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


## The GLB's own nozzle fitting, if the catalog names one: its centreline
## direction (the fitting's authored axis, signed TOWARD the runner) and the
## mouth — the end of the fitting nearest the wheel. Both in _model_root space.
## Measured off the mesh, never hardcoded, so a re-export keeps working.
func _measure_nozzle_base(noz_node: Node3D) -> void:
	_noz_base_dir = Vector3.ZERO
	if noz_node == null:
		return
	var mi := _first_mesh(noz_node)
	if mi == null or mi.mesh == null:
		return
	var xf := _local_chain(mi, _model_root)
	var axis_local := Vector3.BACK
	match ModelCatalog.nozzle_axis_for(_model_id):
		"x": axis_local = Vector3.RIGHT
		"y": axis_local = Vector3.UP
	var dir := (xf.basis * axis_local).normalized()
	var aabb := mi.get_aabb()
	var centre := xf * aabb.get_center()
	if (_runner_centre - centre).dot(dir) < 0.0:
		dir = -dir
	# The mouth is the fitting's extreme along its own axis toward the wheel:
	# project the eight AABB corners and take the farthest.
	var far_t := -INF
	for i in 8:
		var c := aabb.position + Vector3(
				aabb.size.x if (i & 1) != 0 else 0.0,
				aabb.size.y if (i & 2) != 0 else 0.0,
				aabb.size.z if (i & 4) != 0 else 0.0)
		far_t = maxf(far_t, (xf * c - centre).dot(dir))
	_noz_base_mouth = centre + dir * maxf(far_t, 0.0)
	_noz_base_dir = dir


func _has_modelled_nozzle() -> bool:
	return _noz_base_dir.length_squared() > 1e-6


## AABB of the whole instantiated model in _model_root space.
func _model_aabb() -> AABB:
	var out := AABB()
	var first := true
	if _model_root == null:
		return out
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
## The catalog records the spin axis (model-local X for the PowerSpout, Y for
## the vertical-shaft micro Pelton); the centre and radius come from the mesh
## AABB composed up to ModelRoot, using LOCAL transforms because
## global_transform can be stale in a deferred build.
func _measure_runner() -> void:
	var axis_key := ModelCatalog.spin_axis_for(_model_id)
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
	var to_parent := _local_chain(mi, _runner.get_parent())
	_runner_centre_parent = to_parent * aabb.get_center()
	# The axis the WHEEL is actually rotated about: the catalog's model-root
	# axis carried into the parent frame (inverse of the parent's chain up to
	# ModelRoot), the same conversion SiphonTurbineSpin does through world space.
	var parent_chain := _local_chain(_runner.get_parent() as Node3D, _model_root) 			if _runner.get_parent() is Node3D and _runner.get_parent() != _model_root 			else Transform3D.IDENTITY
	_runner_axis_parent = (parent_chain.basis.inverse() * _runner_axis_local).normalized()
	if _runner_axis_parent.length_squared() < 1e-6:
		_runner_axis_parent = Vector3(0, 0, 1)
	# Measured truth: a runner disc is flat along its shaft, so the mesh AABB's
	# thinnest extent IS the shaft in mesh space; carry it to the parent frame.
	var sz := aabb.size
	var thin := Vector3.BACK
	if sz.x <= sz.y and sz.x <= sz.z:
		thin = Vector3.RIGHT
	elif sz.y <= sz.x and sz.y <= sz.z:
		thin = Vector3.UP
	_disc_normal_parent = (to_parent.basis * thin).normalized()
	if absf(_disc_normal_parent.dot(_runner_axis_parent)) < 0.95:
		push_warning("HydroTurbineCloseup: %s spin axis %s (parent frame) is not the disc's normal %s — the wheel would tumble; using the measured normal" % [
				_model_id, str(_runner_axis_parent), str(_disc_normal_parent)])
		_runner_axis_parent = _disc_normal_parent
	# Radius = half the LARGEST extent perpendicular to the axis (a Pelton disc is
	# flat along its axis, so the two big extents are the disc face); thickness
	# = the smallest.
	var ext := (xf.basis * aabb.size).abs()
	var comps := [ext.x, ext.y, ext.z]
	comps.sort()
	_runner_radius = maxf(float(comps[2]) * 0.5, 0.02)
	_runner_thickness = maxf(float(comps[0]), 0.005)
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
	# The procedural nozzle the jet comes OUT of when the GLB has none modelled.
	# Without it the water starts in mid-air, which reads as a floating rod
	# rather than as plumbing (the PowerSpout GLB has three meshes: runner,
	# housing, a bracket plate — no nozzle).
	_nozzle = _make_nozzle()
	_studio.add_child(_nozzle)
	_nozzle2 = _make_nozzle()
	_nozzle2.visible = false
	_studio.add_child(_nozzle2)

	# Mist at the strike: a little of the jet shatters off the splitter edge.
	_splash = _make_spray(0.004, 0.18, SPLASH_MAX)
	_splash_mat = _splash.process_material as ParticleProcessMaterial
	_splash_mat.spread = 70.0
	_studio.add_child(_splash)

	# The exit SHEETS: the bucket splits the jet and turns each half through
	# ~165°, so the water leaves sideways along the shaft — one sheet per side
	# per jet. Tight spread so each reads as a sheet with a direction, not a
	# cloud; velocity straight from PeltonPhysics.bucket_exit_velocity.
	_sheets.clear()
	_sheet_mats.clear()
	for i in 4:
		var sh := _make_spray(0.0045, 0.32, SHEET_MAX)
		var sm := sh.process_material as ParticleProcessMaterial
		sm.spread = 9.0
		_sheets.append(sh)
		_sheet_mats.append(sm)
		_studio.add_child(sh)

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

	# Landing ring: where the jet meets the cups, facing the jet.
	_marker = MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.0085
	tor.outer_radius = 0.011
	tor.rings = 24
	tor.ring_segments = 8
	_marker.mesh = tor
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(0.35, 1.0, 0.95)
	mm.emission_enabled = true
	mm.emission = Color(0.35, 1.0, 0.95)
	mm.emission_energy_multiplier = 1.2
	mm.no_depth_test = true
	mm.render_priority = 10
	_marker.material_override = mm
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.visible = false
	_studio.add_child(_marker)

	# Velocity arrows.
	_arrows.clear()
	for spec: Array in [["jet", Color(0.45, 0.92, 1.0)], ["bucket", Color(1.0, 0.72, 0.25)],
			["exit_a", Color(0.55, 0.70, 1.0)], ["exit_b", Color(0.55, 0.70, 1.0)],
			["exit_a2", Color(0.55, 0.70, 1.0)], ["exit_b2", Color(0.55, 0.70, 1.0)]]:
		var arrow := _make_arrow(spec[1] as Color)
		arrow.visible = false
		_studio.add_child(arrow)
		_arrows[str(spec[0])] = arrow


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
	# A soft round droplet, not a hard square — centimetres from the jet's-eye
	# lens a bare quad reads as confetti.
	qm.albedo_texture = _droplet_texture()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = qm
	p.draw_pass_1 = q
	return p


static var _droplet_tex: GradientTexture2D = null


static func _droplet_texture() -> GradientTexture2D:
	if _droplet_tex != null:
		return _droplet_tex
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.85))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 32
	t.height = 32
	_droplet_tex = t
	return t


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
	# No end caps: seen from behind the mouth (the jet's eye) a capped rod is
	# one flat disc; open, the streaks run away down the tube.
	cyl.cap_top = false
	cyl.cap_bottom = false
	mi.mesh = cyl
	var sm := ShaderMaterial.new()
	sm.shader = load("res://core/conduits/pelton_jet.gdshader")
	mi.material_override = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A unit arrow along local +Y (shaft + head), scaled per use by _seat_arrow.
func _make_arrow(col: Color) -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	mat.render_priority = 9
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0022
	cyl.bottom_radius = 0.0022
	cyl.height = 1.0
	cyl.radial_segments = 8
	cyl.rings = 1
	shaft.mesh = cyl
	shaft.material_override = mat
	shaft.name = "Shaft"
	root.add_child(shaft)
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.007
	cone.height = 0.018
	cone.radial_segments = 10
	cone.rings = 1
	head.mesh = cone
	head.material_override = mat
	head.name = "Head"
	root.add_child(head)
	return root


## Seat an arrow from `from` along `dir` for `len_m` (metres).
func _seat_arrow(arrow: Node3D, from: Vector3, dir: Vector3, len_m: float) -> void:
	if arrow == null:
		return
	var d := dir.normalized() if dir.length_squared() > 1e-9 else Vector3.UP
	var L := maxf(len_m, 0.012)
	arrow.visible = true
	arrow.transform = Transform3D(_basis_along(d), from)
	var shaft := arrow.get_node_or_null("Shaft") as Node3D
	var head := arrow.get_node_or_null("Head") as Node3D
	var head_len := 0.018
	if shaft != null:
		shaft.position = Vector3(0, (L - head_len) * 0.5, 0)
		shaft.scale = Vector3(1, maxf(L - head_len, 0.002), 1)
	if head != null:
		head.position = Vector3(0, L - head_len * 0.5, 0)


func _free_particles() -> void:
	if _splash != null:
		_splash.emitting = false
	if _tailwater != null:
		_tailwater.emitting = false
	for sh in _sheets:
		if is_instance_valid(sh):
			sh.emitting = false


# ---------------------------------------------------------------------------
# Public API (called BY STRING from the Lab — keep the surface stable)
# ---------------------------------------------------------------------------

## {q_lps, h_net_m, v_jet_ms, rpm, speed_ratio, nozzle_d_m, nozzle_n,
##  runner_pcd_m, load_frac, eta_runner, model_id}
func set_state(s: Dictionary) -> void:
	_state = s
	var was_siphon := _siphon
	_siphon = str(s.get("kind", "")) == "siphon"
	if _siphon != was_siphon:
		_last = {}
	var want := str(s.get("model_id", _model_id))
	if not want.is_empty() and want != _model_id:
		_model_id = want
		if _built:
			_rebuild_model()


func set_display_mode(mode: String) -> void:
	_apply_display_mode(mode)


## "side" (along the shaft) or "jet" (from the nozzle mouth down the jet).
func set_camera_mode(mode: String) -> void:
	_apply_camera_mode(mode)


func set_vectors(on: bool) -> void:
	_show_vectors = on
	if not on:
		for a in _arrows.values():
			(a as Node3D).visible = false
	_restyle_buttons()


## Player fine-tune (metres) on the nozzle's aim offset — the perpendicular
## shift of the jet line inside the wheel's plane (height, for a horizontal
## shaft). Kept for the old single-knob Lab call; set_nozzle_pose supersedes it.
func set_nozzle_offset_m(v: float) -> void:
	_noz["offset_m"] = v


## The whole nozzle placement: {offset_m, axial_m, angle_deg, tilt_in_deg,
## tilt_out_deg, standoff_m}. Missing keys keep their value.
func set_nozzle_pose(d: Dictionary) -> void:
	for k in _noz.keys():
		if d.has(k):
			_noz[k] = float(d[k])


## What the last frame resolved — the numbers a PNG cannot prove.
func debug_summary() -> Dictionary:
	var out := _last.duplicate()
	out["model_id"] = _model_id
	out["siphon_mode"] = _siphon
	out["runner"] = _runner != null
	out["runner_radius_m"] = _runner_radius
	out["r_pitch_m"] = _pitch_radius()
	out["runner_axis"] = _runner_axis_local
	out["spin_axis_parent"] = _runner_axis_parent
	out["disc_normal_parent"] = _disc_normal_parent
	out["runner_centre"] = _runner_centre
	out["modelled_nozzle"] = _has_modelled_nozzle()
	out["cam_mode"] = _cam_mode
	out["cam_pos"] = _camera.global_position if _camera != null else Vector3.ZERO
	out["housing_meshes"] = _housing_meshes.size()
	out["nozzle_meshes"] = _nozzle_meshes.size()
	return out


func _apply_display_mode(mode: String) -> void:
	_display_mode = mode
	for mi: MeshInstance3D in _housing_meshes:
		if not is_instance_valid(mi):
			continue
		mi.visible = mode != "runner"
		mi.material_override = _ghost_mat if mode == "cutaway" else null
	# In the jet's-eye view the eye sits INSIDE the modelled fitting; hide it
	# whatever the display mode says.
	if _cam_mode == "jet":
		for mi: MeshInstance3D in _nozzle_meshes:
			if is_instance_valid(mi):
				mi.visible = false
	_restyle_buttons()


func _apply_camera_mode(mode: String) -> void:
	_cam_mode = mode
	if _camera != null:
		_camera.fov = JET_EYE_FOV if mode == "jet" else SIDE_FOV
	_jet_yaw = 0.0
	_jet_pitch = 0.0
	_jet_dolly = 1.0
	# Re-apply the display mode: it owns the nozzle-fitting visibility.
	_apply_display_mode(_display_mode)
	_apply_camera()


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active or not _built or _runner == null:
		return
	_t += delta
	if _siphon:
		_process_siphon(delta)
		return
	_hide_siphon_visuals()
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
		var rot := Basis(_runner_axis_parent.normalized(), _angle)
		_runner.transform = Transform3D(rot,
				_runner_centre_parent - rot * _runner_centre_parent) * _runner_rest
	_update_water(delta, q_lps, v_jet, x)
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


func _update_water(delta: float, q_lps: float, v_jet: float, x: float) -> void:
	if _jet == null:
		return
	var n := maxi(int(_state.get("nozzle_n", 1)), 1)
	var noz_d := maxf(float(_state.get("nozzle_d_m", 0.010)), 0.001)
	var flowing := q_lps > 0.001 and v_jet > 0.01
	var intensity := clampf(q_lps / 2.0, 0.0, 1.0) if flowing else 0.0
	var pose := _nozzle_pose(0)
	var hit: Vector3 = pose["hit"]
	var dir: Vector3 = pose["dir"]
	_seat_jet(_jet, _jet_mat, pose, noz_d, v_jet, intensity)
	_seat_nozzle(_nozzle, pose)
	var pose2 := _nozzle_pose(1)
	_jet2.visible = n >= 2 and flowing
	_nozzle2.visible = n >= 2 and not _has_modelled_nozzle()
	if _jet2.visible:
		_seat_jet(_jet2, _jet2_mat, pose2, noz_d, v_jet, intensity)
	if _nozzle2.visible:
		_seat_nozzle(_nozzle2, pose2)

	# Landing ring on the cups: sized to the jet, facing back up it.
	if _marker != null:
		_marker.visible = _cam_mode == "jet" or _show_vectors
		if _marker.visible:
			var s := maxf(noz_d, 0.003) / 0.02
			_marker.transform = Transform3D(_basis_along(dir) * Basis.from_scale(Vector3(s, 1.0, s)), hit)

	# Exit velocity off the bucket: the relative flow turned through ~165°, plus
	# the bucket's own speed. Sideways along the shaft, a little fore/aft.
	var ex := PeltonPhysics.bucket_exit_velocity(v_jet, x)
	var axis := _runner_axis_local.normalized()
	var tang := float(ex["tangential"])
	var ax := float(ex["axial"])
	var v_a := dir * tang + axis * ax
	var v_b := dir * tang - axis * ax
	# How the jet's landing splits between the two halves of the splitter: a jet
	# aimed off-centre along the shaft feeds that side more. ±1 = all one side.
	var split := clampf((hit - _runner_centre).dot(axis) / maxf(_runner_thickness * 0.5, 1e-3), -1.0, 1.0)
	var share_a := clampf(0.5 + 0.5 * split, 0.0, 1.0)
	var share_b := 1.0 - share_a
	var exit_speed := float(ex["speed"])
	for i in 4:
		var sh := _sheets[i]
		var sm := _sheet_mats[i]
		var second := i >= 2
		var is_a := (i % 2) == 0
		var on := flowing and (not second or n >= 2)
		sh.emitting = on
		if not on:
			continue
		var p2 := pose if not second else pose2
		var d2: Vector3 = p2["dir"]
		var vv := (d2 * tang + axis * (ax if is_a else -ax))
		sh.global_position = (p2["hit"] as Vector3) + axis * (0.004 if is_a else -0.004)
		sm.direction = vv.normalized() if vv.length_squared() > 1e-8 else axis
		# Capped because a stalled bucket's ~17 m/s would clear the frame in a
		# frame; the floor keeps a matched-load dribble visible.
		sm.initial_velocity_min = clampf(exit_speed * 0.85, 0.12, 3.5)
		sm.initial_velocity_max = clampf(exit_speed * 1.10, 0.22, 5.0)
		sh.amount_ratio = lerpf(0.15, 1.0, intensity) * (share_a if is_a else share_b)

	if _splash != null:
		_splash.emitting = flowing
		_splash.amount_ratio = lerpf(0.15, 0.6, intensity)
		if flowing:
			_splash.global_position = hit
			_splash_mat.direction = (-dir + Vector3(0, 0.3, 0)).normalized()
			_splash_mat.initial_velocity_min = 0.08
			_splash_mat.initial_velocity_max = clampf(exit_speed * 0.4, 0.2, 1.2)
	if _tailwater != null:
		_tailwater.emitting = flowing
		_tailwater.amount_ratio = lerpf(0.3, 1.0, intensity)
		if flowing:
			_tailwater.global_position = _housing_bottom
			_tailwater_mat.initial_velocity_min = lerpf(0.10, 0.35, intensity)
			_tailwater_mat.initial_velocity_max = lerpf(0.25, 0.70, intensity)

	# Velocity arrows: lengths in one scale (the jet's arrow ≈ 0.9 r), so the
	# bucket's u and the exits read as fractions of the jet.
	if _show_vectors and flowing:
		var k := 0.9 * _runner_radius / maxf(v_jet, 0.5)
		var u := x * v_jet
		if _cam_mode == "jet":
			(_arrows["jet"] as Node3D).visible = false   # the eye looks along it
		else:
			_seat_arrow(_arrows["jet"], hit - dir * (v_jet * k), dir, v_jet * k)
		_seat_arrow(_arrows["bucket"], hit, dir, u * k)
		_seat_arrow(_arrows["exit_a"], hit, v_a, v_a.length() * k)
		_seat_arrow(_arrows["exit_b"], hit, v_b, v_b.length() * k)
		if n >= 2:
			var d2b: Vector3 = pose2["dir"]
			var h2: Vector3 = pose2["hit"]
			_seat_arrow(_arrows["exit_a2"], h2, d2b * tang + axis * ax, v_a.length() * k)
			_seat_arrow(_arrows["exit_b2"], h2, d2b * tang - axis * ax, v_b.length() * k)
		else:
			(_arrows["exit_a2"] as Node3D).visible = false
			(_arrows["exit_b2"] as Node3D).visible = false
	else:
		for a in _arrows.values():
			(a as Node3D).visible = false

	_last = {"hit": hit, "mouth": pose["mouth"], "dir": dir, "x": x,
		"u_ms": x * v_jet, "exit_tangential_ms": tang, "exit_axial_ms": ax,
		"exit_speed_ms": exit_speed, "split": split, "flowing": flowing,
		"jet_len_m": (pose["mouth"] as Vector3).distance_to(hit)}


# ---------------------------------------------------------------------------
# Siphon mode — propeller in a pipe, the pond's surface, the flow through it
# ---------------------------------------------------------------------------

func _process_siphon(delta: float) -> void:
	if not _s_built:
		_build_siphon_visuals()
	var q_lps := float(_state.get("q_lps", 0.0))
	var primed := bool(_state.get("primed", false))
	var flowing := primed and q_lps > 0.01
	# Runner: the reach's own rpm (tip-speed law), display-compressed like the
	# Pelton so a 1300 rpm prop does not alias into a crawl.
	var rpm := maxf(float(_state.get("rpm", 0.0)), 0.0)
	_s_rpm_true = rpm if flowing else 0.0
	var target_omega := _display_omega(_s_rpm_true * TAU / 60.0) if flowing else 0.0
	var tau := TAU_SHED_S if target_omega > _omega else TAU_LOAD_S
	_omega = lerpf(_omega, target_omega, clampf(1.0 - exp(-delta / tau), 0.0, 1.0))
	if absf(_omega) > 0.02:
		_angle = wrapf(_angle + _omega * delta, -TAU, TAU)
		var rot := Basis(_runner_axis_parent.normalized(), _angle)
		_runner.transform = Transform3D(rot,
				_runner_centre_parent - rot * _runner_centre_parent) * _runner_rest
	_update_siphon_water(delta, flowing, q_lps)
	_update_siphon_hud(flowing, q_lps)
	if _overlay_hint != null and _overlay_hint.text.begins_with("Side —"):
		_overlay_hint.text = "Siphon elevation — the pond's surface, the dip tube, the runner in its pipe, the draft · drag to orbit · wheel to zoom"
	for a in _arrows.values():
		(a as Node3D).visible = false
	if _marker != null:
		_marker.visible = false
	_apply_camera()


func _hide_siphon_visuals() -> void:
	if not _s_built:
		return
	for mi in [_s_waterline, _s_column, _s_leg, _s_dip, _s_draft]:
		if mi != null:
			(mi as MeshInstance3D).visible = false
	for b in _s_beads:
		b.visible = false


## The housing's two legs — the vertical riser and the horizontal leg the
## runner sits in — measured by the SHARED SiphonGeometry helper so the dip
## tube hangs from the same fitting here and in the world (`SiphonDipTube`).
## Returns {riser: AABB, leg: AABB} in model-root space, or empty.
func _siphon_legs() -> Dictionary:
	if _model_root == null:
		return {}
	return SiphonGeometry.pipe_legs(_model_root, _housing_meshes, _runner_axis_local, _runner_centre)


func _s_make_tube(col: Color, alpha: float, unshaded: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 18
	cyl.rings = 1
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	_studio.add_child(mi)
	return mi


func _s_seat_tube(mi: MeshInstance3D, a: Vector3, b: Vector3, r: float) -> void:
	var cyl := mi.mesh as CylinderMesh
	var seg := b - a
	var len := seg.length()
	if len < 1e-4:
		mi.visible = false
		return
	cyl.height = len
	cyl.top_radius = r
	cyl.bottom_radius = r
	var y := seg / len
	var x := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	x = (x - y * x.dot(y)).normalized()
	var z := x.cross(y).normalized()
	mi.transform = Transform3D(Basis(x, y, z), (a + b) * 0.5)
	mi.visible = true


func _build_siphon_visuals() -> void:
	_s_built = true
	# The pond's surface: a wide flat plane, double-sided, pale water.
	_s_waterline = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2.4, 2.4)
	_s_waterline.mesh = pm
	var wm := StandardMaterial3D.new()
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.albedo_color = Color(0.25, 0.55, 0.90, 0.35)
	wm.cull_mode = BaseMaterial3D.CULL_DISABLED
	wm.roughness = 0.1
	_s_waterline.material_override = wm
	_s_waterline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_s_waterline.visible = false
	_studio.add_child(_s_waterline)
	# Water inside the pipes (a shade darker, drawn on top of the ghosted
	# housing), the dip tube and the draft tube (PVC white / black PE).
	_s_column = _s_make_tube(Color(0.30, 0.62, 0.95), 0.55, true)
	_s_leg = _s_make_tube(Color(0.30, 0.62, 0.95), 0.55, true)
	_s_dip = _s_make_tube(Color(0.92, 0.92, 0.88), 0.9)
	_s_draft = _s_make_tube(Color(0.12, 0.12, 0.13), 0.95)
	# Flow beads: small bright spheres riding the path.
	_s_beads.clear()
	for i in S_BEADS:
		var b := MeshInstance3D.new()
		var sp := SphereMesh.new()
		sp.radius = S_BEAD_R
		sp.height = S_BEAD_R * 2.0
		sp.radial_segments = 10
		sp.rings = 5
		b.mesh = sp
		var bm := StandardMaterial3D.new()
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.albedo_color = Color(0.65, 0.92, 1.0, 0.95)
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		b.material_override = bm
		b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.visible = false
		_studio.add_child(b)
		_s_beads.append(b)


func _update_siphon_water(delta: float, flowing: bool, q_lps: float) -> void:
	var legs := _siphon_legs()
	var dip_d := clampf(float(_state.get("dip_d_m", 0.152)), 0.03, 0.4)
	var draft_d := clampf(float(_state.get("draft_d_m", 0.203)), 0.03, 0.5)
	var dip_len := clampf(float(_state.get("dip_len_m", 1.0)), 0.1, 30.0)
	var level_rel := float(_state.get("level_rel_m", NAN))
	var axis := _runner_axis_local.normalized()
	var rc := _runner_centre
	var r := _runner_radius
	# Geometry frame. With the GLB's pipes measured, the riser is the crest
	# and the leg carries the runner; without them, a generic T around the
	# runner at its own radius.
	var leg_r := r * 1.05
	var leg_a := rc + axis * (r * 1.6)        # the intake end of the leg
	var leg_b := rc - axis * (r * 1.6)        # the riser end
	var riser_top := leg_b + Vector3.UP * (r * 2.2)
	var riser_bot := leg_b + Vector3.DOWN * (r * 1.4)
	var riser_r := r * 0.95
	if legs.has("leg"):
		var lb: AABB = legs["leg"]
		var c := lb.get_center()
		var half := absf(lb.size.dot(axis)) * 0.5
		leg_a = c + axis * half
		leg_b = c - axis * half
		# The intake end is the one the runner sits nearer.
		if rc.distance_to(leg_b) < rc.distance_to(leg_a):
			var t := leg_a
			leg_a = leg_b
			leg_b = t
		leg_r = maxf(lb.size.x, lb.size.z) * 0.5 if absf(axis.y) < 0.5 else maxf(lb.size.x, lb.size.y) * 0.5
	if legs.has("riser"):
		var rb: AABB = legs["riser"]
		var rcn := rb.get_center()
		riser_top = Vector3(rcn.x, rb.end.y, rcn.z)
		riser_bot = Vector3(rcn.x, rb.position.y, rcn.z)
		riser_r = maxf(rb.size.x, rb.size.z) * 0.5
	# The dip tube hangs from the intake end; the draft tube leaves under the
	# riser. Both clamped so the studio stays framed.
	var mouth := leg_a + Vector3.DOWN * minf(dip_len, 1.1)
	var draft_end := riser_bot + Vector3.DOWN * 0.9
	_s_seat_tube(_s_dip, leg_a + Vector3.DOWN * (leg_r * 0.2), mouth, dip_d * 0.5)
	_s_seat_tube(_s_draft, riser_bot, draft_end, draft_d * 0.5)
	# Water: primed = every pipe full; otherwise the column stands at the
	# pond's level inside the dip tube and leg (what a dry siphon looks like).
	var primed := bool(_state.get("primed", false))
	if primed:
		_s_seat_tube(_s_leg, leg_a, leg_b, leg_r * 0.92)
		_s_seat_tube(_s_column, riser_bot, riser_top, riser_r * 0.92)
	else:
		var wl := level_rel if not is_nan(level_rel) else mouth.y
		# The dip tube fills to the pond level; the leg only if the level reaches it.
		var top_y := clampf(wl, mouth.y, leg_a.y)
		if top_y > mouth.y + 0.005:
			_s_seat_tube(_s_column, Vector3(mouth.x, mouth.y, mouth.z), Vector3(mouth.x, top_y, mouth.z), dip_d * 0.46)
		else:
			_s_column.visible = false
		if wl >= leg_a.y - leg_r * 0.5:
			_s_seat_tube(_s_leg, leg_a, leg_b, leg_r * 0.92)
		else:
			_s_leg.visible = false
	# The pond's surface relative to the turbine.
	if not is_nan(level_rel):
		_s_waterline.visible = true
		_s_waterline.position = Vector3(rc.x, clampf(level_rel, mouth.y - 0.2, riser_top.y + 0.6), rc.z)
		var wm := _s_waterline.material_override as StandardMaterial3D
		wm.albedo_color = Color(0.25, 0.55, 0.90, 0.35 if primed else 0.28)
	else:
		_s_waterline.visible = false
	# Flow: beads riding mouth → up the dip tube → along the leg through the
	# runner → up the riser (the crest) → down the draft tube.
	_s_path = PackedVector3Array([mouth, leg_a + Vector3.DOWN * (leg_r * 0.2), leg_a, leg_b, riser_top, riser_top, riser_bot, draft_end])
	var v := clampf(float(_state.get("v_draft_ms", 0.0)), 0.0, 12.0)
	var speed := minf(v * 0.25, S_FLOW_MAX_MPS)
	if flowing and speed > 1e-3:
		var total := 0.0
		for i in range(1, _s_path.size()):
			total += _s_path[i - 1].distance_to(_s_path[i])
		_s_phase = fmod(_s_phase + speed * delta / maxf(total, 1e-3), 1.0)
		for i in S_BEADS:
			var u := fmod(_s_phase + float(i) / float(S_BEADS), 1.0)
			_s_beads[i].position = _s_path_point(u * total)
			_s_beads[i].visible = true
	else:
		for b in _s_beads:
			b.visible = false
	if _tailwater != null:
		_tailwater.emitting = flowing
		_tailwater.amount_ratio = lerpf(0.3, 1.0, clampf(q_lps / 60.0, 0.0, 1.0))
		if flowing:
			_tailwater.global_position = draft_end
			_tailwater_mat.initial_velocity_min = clampf(v * 0.3, 0.1, 0.6)
			_tailwater_mat.initial_velocity_max = clampf(v * 0.5, 0.25, 1.0)
	_last = {"flowing": flowing, "siphon": true, "mouth": mouth, "riser_top": riser_top,
		"draft_end": draft_end, "level_rel_m": level_rel, "beads": S_BEADS if flowing else 0,
		"rpm": _s_rpm_true}


func _s_path_point(dist: float) -> Vector3:
	var d := dist
	for i in range(1, _s_path.size()):
		var seg := _s_path[i - 1].distance_to(_s_path[i])
		if d <= seg or i == _s_path.size() - 1:
			return _s_path[i - 1].lerp(_s_path[i], clampf(d / maxf(seg, 1e-6), 0.0, 1.0))
		d -= seg
	return _s_path[_s_path.size() - 1]


func _update_siphon_hud(flowing: bool, q_lps: float) -> void:
	if _hud == null:
		return
	var lvl := float(_state.get("level_rel_m", NAN))
	var state := str(_state.get("regime", ""))
	var txt := "siphon — pond %s · " % (("%+.2f m vs the turbine" % lvl) if not is_nan(lvl) else "?")
	if flowing:
		txt += "Q %.1f L/s · runner head %.2f m · %.0f rpm · suction %.1f / %.1f m%s" % [
			q_lps, float(_state.get("turbine_head_m", 0.0)), _s_rpm_true,
			float(_state.get("suction_m", 0.0)), float(_state.get("suction_max_m", 0.0)),
			" · CAVITATING" if bool(_state.get("cavitating", false)) else ""]
	else:
		txt += {"dry": "not primed — the pond must reach the prime level",
			"broken": "broken — the dip mouth is out of the water",
			"lift_exceeded": "lift too high — the column lets go at the crest",
			"no_head": "no head — the exit is not below the pond"}.get(state, "standing still (%s)" % state)
	_hud.text = txt


# ---------------------------------------------------------------------------
# Nozzle pose — where the jet comes from and where it lands
# ---------------------------------------------------------------------------

## A unit direction lying IN the wheel's plane (perpendicular to the spin axis),
## preferring a horizontal one — a PowerSpout's nozzle enters from the side, and a
## side-on camera looks ALONG the axis, so an in-plane jet is the only one visible.
func _jet_side() -> Vector3:
	var axis := _runner_axis_local.normalized()
	var s := axis.cross(Vector3.UP)
	if s.length_squared() < 1e-5:
		s = axis.cross(Vector3.BACK)
	return s.normalized()


## The full nozzle pose for jet `index` (0 or 1): {mouth, dir, hit} in
## _model_root space, from the model's base pose with the player's placement
## applied. The second jet is the first turned half a revolution about the
## shaft — both then drive the wheel the same way, as a twin-jet Pelton does.
func _nozzle_pose(index: int) -> Dictionary:
	var axis := _runner_axis_local.normalized()
	var mouth: Vector3
	var dir: Vector3
	if _has_modelled_nozzle():
		mouth = _noz_base_mouth
		dir = _noz_base_dir
	else:
		# Procedural nozzle off the real inlet port: outboard of the wheel on the
		# horizontal, at the port's height, aimed straight in.
		var side := _jet_side()
		mouth = _runner_centre + side * (_runner_radius * 2.1) + Vector3.UP * _port_dy
		dir = -side
	# Player placement, in the nozzle's own frame.
	var ang := deg_to_rad(float(_noz["angle_deg"]))
	if absf(ang) > 1e-6:
		var ra := Basis(axis, ang)
		mouth = _runner_centre + ra * (mouth - _runner_centre)
		dir = ra * dir
	# In-plane perpendicular to the jet: the aim offset moves the line toward or
	# away from the shaft (height on a horizontal-shaft machine).
	var n_in := axis.cross(dir)
	if n_in.length_squared() < 1e-6:
		n_in = _jet_side()
	n_in = n_in.normalized()
	mouth += n_in * float(_noz["offset_m"]) + axis * float(_noz["axial_m"])
	var t_in := deg_to_rad(float(_noz["tilt_in_deg"]))
	if absf(t_in) > 1e-6:
		dir = Basis(axis, t_in) * dir
	var t_out := deg_to_rad(float(_noz["tilt_out_deg"]))
	if absf(t_out) > 1e-6:
		dir = Basis(n_in, t_out) * dir
	dir = dir.normalized()
	mouth -= dir * float(_noz["standoff_m"])
	if index == 1:
		var half := Basis(axis, PI)
		mouth = _runner_centre + half * (mouth - _runner_centre)
		dir = half * dir
	return {"mouth": mouth, "dir": dir, "hit": _impact_from(mouth, dir)}


## The runner's PITCH radius — where the splitter ridges run, from the kind's
## PCD — kept inside the tip radius. The landing is measured here, not at the
## tip: a jet on the pitch chord crosses the TIP circle well before the
## tangent point, grazing the first bucket's outer edge, and a landing ring
## drawn there reads as the jet hitting the cups from the side (which is how
## the first jet's-eye shot looked; the runner was fine).
func _pitch_radius() -> float:
	var pcd := float(_state.get("runner_pcd_m", 0.0))
	var r := pcd * 0.5 if pcd > 0.001 else _runner_radius * 0.85
	return clampf(r, _runner_radius * 0.5, _runner_radius * 0.97)


## Where a jet from `mouth` along `dir` meets the runner's pitch cylinder (the
## pitch radius about the shaft) — the first crossing in front of the mouth; a
## jet laid exactly on the pitch chord lands at the tangent point. A jet that
## misses lands at its closest approach instead, so a wildly mis-aimed nozzle
## still shows SOMETHING rather than nothing.
func _impact_from(mouth: Vector3, dir: Vector3) -> Vector3:
	var axis := _runner_axis_local.normalized()
	var p := mouth - _runner_centre
	var p_perp := p - axis * p.dot(axis)
	var d_perp := dir - axis * dir.dot(axis)
	var a := d_perp.dot(d_perp)
	if a < 1e-9:
		return mouth
	var b := 2.0 * p_perp.dot(d_perp)
	var r_p := _pitch_radius()
	var c := p_perp.dot(p_perp) - r_p * r_p
	var disc := b * b - 4.0 * a * c
	var t: float
	# A chord within a hair of the pitch radius is a tangent, not a miss.
	if disc < 1e-7:
		t = maxf(-b / (2.0 * a), 0.0)   # closest approach / tangent point
	else:
		var sq := sqrt(disc)
		t = (-b - sq) / (2.0 * a)
		if t < 0.0:
			t = (-b + sq) / (2.0 * a)
		t = maxf(t, 0.0)
	return mouth + dir * t


## Park the procedural nozzle so its TIP is exactly the jet's mouth and its
## bore points down the jet. Unlike the jet it does not stretch — a nozzle is
## a fixed object. Hidden entirely when the GLB models its own fitting.
func _seat_nozzle(root: Node3D, pose: Dictionary) -> void:
	if root == null:
		return
	if _has_modelled_nozzle():
		root.visible = false
		return
	var mouth: Vector3 = pose["mouth"]
	var dir: Vector3 = pose["dir"]
	root.transform = Transform3D(_basis_along(dir), mouth - dir * NOZZLE_LEN_M)


## An orthonormal basis whose local +Y runs along `dir` (CylinderMesh's own axis).
func _basis_along(dir: Vector3) -> Basis:
	var up := dir.normalized()
	var fwd := up.cross(Vector3.UP)
	if fwd.length_squared() < 1e-5:
		fwd = up.cross(Vector3.BACK)
	fwd = fwd.normalized()
	return Basis(up.cross(fwd).normalized(), up, fwd)


func _seat_jet(mi: MeshInstance3D, mat: ShaderMaterial, pose: Dictionary,
		noz_d: float, v_jet: float, intensity: float) -> void:
	if mi == null or mat == null:
		return
	mi.visible = intensity > 0.001
	if not mi.visible:
		return
	var hit: Vector3 = pose["hit"]
	var mouth: Vector3 = pose["mouth"]
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
	var line := "%s — v_jet %.1f m/s · x %.2f · %.0f rpm · %.0f W (%.0f%% of matched) · Q %.2f L/s" % [
		tag, v_jet, x, _true_rpm, w, frac * 100.0, q_lps]
	if _show_vectors or _cam_mode == "jet":
		var ex := PeltonPhysics.bucket_exit_velocity(v_jet, x)
		var split := float(_last.get("split", 0.0))
		var where := "on the splitter" if absf(split) < 0.15 else (
			"%.0f%% to one side" % (absf(split) * 100.0))
		line += "\nbucket %.1f m/s · leaves %.1f m/s (%.1f sideways, %+.1f along) turned %.0f° · landing %s" % [
			x * v_jet, float(ex["speed"]), float(ex["axial"]), float(ex["tangential"]),
			PeltonPhysics.BUCKET_DEFLECTION_DEG, where]
	_hud.text = line


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

## Side-on: the camera looks ALONG the shaft at the centre, so the wheel reads
## as a disc with the jet hitting a bucket tangentially — whichever way the
## shaft runs (the PowerSpout's is horizontal, the micro Pelton's vertical).
func _frame_camera() -> void:
	# Far enough back that the wheel fills a comfortable share of the frame, and —
	# the part that matters — always OUTSIDE the housing shell, whose extent along
	# the view axis is unknown until the model is measured.
	# The frame height at distance d is 2·d·tan(fov/2); size it so the WHOLE
	# machine fits with margin, then never closer than clear of the shell.
	var shell := _model_aabb()
	var span := maxf(shell.size.x, maxf(shell.size.y, shell.size.z))
	var fit := (span * 1.45) / (2.0 * tan(deg_to_rad(SIDE_FOV * 0.5)))
	_dist = clampf(maxf(fit, span * 0.9), DIST_MIN, DIST_MAX)
	_orbit_yaw = 0.0
	_orbit_pitch = -6.0
	_apply_camera()


## The orbit frame for the side view: `up` is a direction perpendicular to the
## shaft (world UP unless the shaft IS vertical), `right` completes it.
func _orbit_frame() -> Array:
	var axis := _runner_axis_local.normalized()
	var up := Vector3.UP
	if absf(axis.dot(up)) > 0.9:
		up = Vector3.BACK
	up = (up - axis * up.dot(axis)).normalized()
	var right := axis.cross(up).normalized()
	return [axis, up, right]


func _apply_camera() -> void:
	if _camera == null:
		return
	if _cam_mode == "jet":
		_apply_jet_camera()
		return
	var f := _orbit_frame()
	var axis: Vector3 = f[0]
	var up: Vector3 = f[1]
	var right: Vector3 = f[2]
	var basis := Basis(up, deg_to_rad(_orbit_yaw)) * Basis(right, deg_to_rad(_orbit_pitch))
	var target := _runner_centre
	var view_dir := axis
	var dist := _dist
	if _siphon:
		# A propeller in a pipe reads as a side ELEVATION, like the cut: look
		# across the shaft so the riser, the leg, the dip tube and the draft
		# all show, and frame the whole thing (the dip tube hangs ~1 m).
		view_dir = right
		var lo_y := _runner_centre.y - 0.9
		var hi_y := _runner_centre.y + 0.5
		# `_last` is shared with the Pelton path, whose "mouth" is the nozzle's;
		# only a siphon frame carries riser_top — key on that, never on mouth.
		if bool(_last.get("siphon", false)) and _last.has("riser_top") and _last.has("mouth"):
			lo_y = minf(lo_y, (_last["mouth"] as Vector3).y - 0.1)
			hi_y = maxf(hi_y, (_last["riser_top"] as Vector3).y + 0.15)
		var lvl := float(_state.get("level_rel_m", NAN))
		if not is_nan(lvl):
			lo_y = minf(lo_y, lvl - 0.15)
			hi_y = maxf(hi_y, lvl + 0.15)
		target = Vector3(_runner_centre.x, (lo_y + hi_y) * 0.5, _runner_centre.z)
		var span := maxf(hi_y - lo_y, 0.6)
		dist = clampf(maxf(_dist, (span * 1.25) / (2.0 * tan(deg_to_rad(SIDE_FOV * 0.5)))), DIST_MIN, 6.0)
	var eye := target + basis * (view_dir * dist)
	_camera.global_position = eye
	_camera.look_at(target, up)


## Jet's eye: just behind the mouth, lifted off the jet line so the rod does
## not fill the frame, looking at the landing ring. A drag nudges the eye round
## the landing point; the wheel dollies along the jet.
func _apply_jet_camera() -> void:
	var pose := _nozzle_pose(0)
	var mouth: Vector3 = pose["mouth"]
	var dir: Vector3 = pose["dir"]
	var hit: Vector3 = pose["hit"]
	var axis := _runner_axis_local.normalized()
	var n_in := axis.cross(dir)
	if n_in.length_squared() < 1e-6:
		n_in = _jet_side()
	n_in = n_in.normalized()
	var noz_d := maxf(float(_state.get("nozzle_d_m", 0.010)), 0.003)
	var back := (JET_EYE_BACK_M + mouth.distance_to(hit) * (_jet_dolly - 1.0))
	var eye := mouth - dir * back + n_in * maxf(noz_d * JET_EYE_LIFT_FRAC, JET_EYE_LIFT_MIN_M)
	# Nudge: rotate the eye about the landing point.
	var rel := eye - hit
	rel = Basis(n_in, deg_to_rad(_jet_yaw)) * rel
	rel = Basis(axis, deg_to_rad(_jet_pitch)) * rel
	_camera.global_position = hit + rel
	var look_up := n_in
	if absf(look_up.dot((hit - _camera.global_position).normalized())) > 0.98:
		look_up = axis
	_camera.look_at(hit, look_up)


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if _cam_mode == "jet":
				_jet_dolly = clampf(_jet_dolly / 1.12, 0.3, 2.5)
			else:
				_dist = clampf(_dist / 1.12, DIST_MIN, DIST_MAX)
			_apply_camera()
			_container.accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if _cam_mode == "jet":
				_jet_dolly = clampf(_jet_dolly * 1.12, 0.3, 2.5)
			else:
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
		if _cam_mode == "jet":
			_jet_yaw = clampf(_jet_yaw - d.x * 0.25, -JET_ORBIT_LIMIT_DEG, JET_ORBIT_LIMIT_DEG)
			_jet_pitch = clampf(_jet_pitch - d.y * 0.25, -JET_ORBIT_LIMIT_DEG, JET_ORBIT_LIMIT_DEG)
		else:
			# Clamped so the side-on read — the reason this view exists — is never lost.
			_orbit_yaw = clampf(_orbit_yaw - d.x * 0.35, -ORBIT_LIMIT_DEG, ORBIT_LIMIT_DEG)
			_orbit_pitch = clampf(_orbit_pitch - d.y * 0.35, -ORBIT_LIMIT_DEG, ORBIT_LIMIT_DEG)
		_apply_camera()
		_container.accept_event()

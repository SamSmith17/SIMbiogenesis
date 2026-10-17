class_name SiphonStateRing
extends Node3D

## What the turbine is DOING, readable from across the pond: an emissive ring
## round the machine's foot and a status label over it, both driven by the
## graph item's live telemetry (the same 0.5 s poll SiphonTurbineSpin and
## SiphonDipTube make). Colours: green = generating, amber = primed but no
## power (or running dry of load), red = the siphon broke / the lift is over
## the atmospheric limit / cavitating, grey = not primed. The label reads the
## regime, the flow and the watts ("PRIMED · 70 L/s · 144 W", "NOT PRIMED —
## pond below the crest") and shrinks with distance the way NPC name tags do,
## so it is legible beside the machine and still a word from 30 m, then
## fades out past LABEL_FAR_M. When the siphon has BROKEN the dip tube's
## mouth bubbles — "sucking air" made literal — from the measured intake
## fitting (SiphonGeometry), whether or not the tube itself is shown.
##
## Attached by PlacedPropRuntime for siphon / hydro-turbine props next to the
## spin runtime. Pure visual: nothing here writes to the graph.

const _POLL_S := 0.5
const LABEL_FAR_M := 60.0
const LABEL_REF_M := 6.0
const C_GEN := Color(0.30, 0.92, 0.45)
const C_PRIMED := Color(0.98, 0.76, 0.22)
const C_FAULT := Color(0.96, 0.30, 0.24)
const C_IDLE := Color(0.55, 0.60, 0.66)

var graph_item_id: String = ""
var model_id: String = ""
var runner_node_name: String = ""

var _poll_acc: float = 999.0
var _sgv: Node = null
var _ring: MeshInstance3D = null
var _ring_mat: StandardMaterial3D = null
var _label: Label3D = null
var _bubbles: GPUParticles3D = null
var _state := "idle"
var _text := ""
var _color := C_IDLE
var _pulse_t := 0.0
var _built := false
var _last_specs: Dictionary = {}


func configure(item_id: String, p_model_id: String = "", runner_name: String = "") -> void:
	graph_item_id = item_id
	model_id = p_model_id
	runner_node_name = runner_name


func _ready() -> void:
	call_deferred("_build")


func _model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	return mr if mr != null else (p as Node3D)


## The machine's footprint in the PARENT (prop) frame, from its meshes'
## local transforms — the ring sits on the ground round it.
func _model_aabb_local() -> AABB:
	var root := _model_root()
	var out := AABB()
	var first := true
	if root == null:
		return out
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var a := SiphonGeometry.local_chain(mi, root) * mi.mesh.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	# Into the prop frame (ModelRoot's own transform).
	return root.transform * out if not first else out


func _build() -> void:
	if _built:
		return
	_built = true
	var box := _model_aabb_local()
	var c := box.get_center()
	var r := maxf(Vector2(box.size.x, box.size.z).length() * 0.5 + 0.25, 0.6)
	_ring = MeshInstance3D.new()
	_ring.name = "StateRing"
	var torus := TorusMesh.new()
	torus.inner_radius = r - 0.06
	torus.outer_radius = r + 0.06
	torus.rings = 32
	torus.ring_segments = 8
	_ring.mesh = torus
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(C_IDLE.r, C_IDLE.g, C_IDLE.b, 0.7)
	_ring_mat.emission_enabled = true
	_ring_mat.emission = C_IDLE
	_ring_mat.emission_energy_multiplier = 1.2
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.position = Vector3(c.x, box.position.y + 0.04, c.z)
	add_child(_ring)
	_label = Label3D.new()
	_label.name = "StateLabel"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = false
	_label.pixel_size = 0.004
	_label.font_size = 48
	_label.outline_size = 10
	_label.modulate = Color(0.95, 0.97, 1.0)
	_label.outline_modulate = Color(0.02, 0.04, 0.08, 0.9)
	_label.position = Vector3(c.x, box.end.y + 0.45, c.z)
	_label.text = ""
	add_child(_label)
	_bubbles = GPUParticles3D.new()
	_bubbles.name = "AirBubbles"
	_bubbles.amount = 60
	_bubbles.lifetime = 1.4
	_bubbles.emitting = false
	_bubbles.local_coords = false
	_bubbles.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 8, 6))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.09
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 18.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.3
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = 0.03
	pm.scale_max = 0.07
	_bubbles.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.06, 0.06)
	var bm := StandardMaterial3D.new()
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.albedo_color = Color(0.85, 0.95, 1.0, 0.75)
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = bm
	_bubbles.draw_pass_1 = qm
	add_child(_bubbles)
	_place_bubbles()


## The bubbles rise from the dip tube's MOUTH (the fitting, straight down the
## tube's length) — where a broken siphon sucks air.
func _place_bubbles() -> void:
	if _bubbles == null:
		return
	var root := _model_root()
	if root == null:
		return
	var fit := SiphonGeometry.fitting_for_model_root(root, model_id, runner_node_name)
	var dip_len := clampf(float(_last_specs.get("dip_tube_length_m", 1.0)), 0.1, 30.0)
	var top_w: Vector3 = (root.global_transform * (fit["pos"] as Vector3)) if not fit.is_empty() else root.global_position
	_bubbles.global_position = top_w + Vector3.DOWN * dip_len


func _process(delta: float) -> void:
	_pulse_t += delta
	_poll_acc += delta
	if _poll_acc >= _POLL_S:
		_poll_acc = 0.0
		_refresh()
	if _ring_mat != null:
		var k := 1.0
		if _state == "fault":
			k = 0.75 + 0.25 * sin(_pulse_t * 5.0)
		elif _state == "generating":
			k = 0.9 + 0.1 * sin(_pulse_t * 2.0)
		_ring_mat.emission_energy_multiplier = 1.3 * k
	if _label != null:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			var d := cam.global_position.distance_to(_label.global_position)
			var s := sqrt(maxf(1.0, d / LABEL_REF_M))
			_label.scale = Vector3.ONE * s
			var a := 1.0 - clampf((d - LABEL_FAR_M * 0.7) / (LABEL_FAR_M * 0.3), 0.0, 1.0)
			_label.modulate.a = a
			_label.outline_modulate.a = 0.9 * a
			_label.visible = a > 0.02 and not _text.is_empty()


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _system_graph_view(main: Node) -> Node:
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	return ui.get_node_or_null("SystemGraphView") if ui != null else null


## State from the live specs. Pure, so the harness can pin it.
static func state_for(specs: Dictionary) -> Dictionary:
	var regime := str(specs.get("live_regime", ""))
	var primed := bool(specs.get("siphon_primed", false))
	var q := float(specs.get("live_q_lps", 0.0))
	var p := float(specs.get("live_power_w", 0.0))
	var has_penstock := bool(HydroSource.kind_meta(str(specs.get("turbine_kind", "siphon"))).get("has_penstock", false))
	var state := "idle"
	var text := ""
	if bool(specs.get(HydroSource.SPEC_OFF, false)):
		# Shut off by the player (double-click in the graph): the valve is
		# closed, so no water moves and nothing is made, whatever the pond does.
		return {"state": "off", "text": "OFF — double-click in the graph to start",
			"regime": regime}
	if regime in ["lift_exceeded", "cavitating", "broken", "siphon_broken"]:
		state = "fault"
		match regime:
			"lift_exceeded": text = "LIFT TOO HIGH — the column lets go"
			"cavitating": text = "CAVITATING · %s · %.0f W" % [_lps_text(q), p]
			_: text = "BROKEN — sucking air"
	elif p > 1.0:
		state = "generating"
		text = "%s · %s · %.0f W" % ["RUNNING" if has_penstock else "PRIMED", _lps_text(q), p]
	elif primed or q > 0.05:
		state = "primed"
		text = "PRIMED · %s · no power" % _lps_text(q)
	else:
		state = "idle"
		text = "DRY — no water at the intake" if has_penstock else "NOT PRIMED — pond below the crest"
	return {"state": state, "text": text, "regime": regime}


## 1.5 L/s used to print as "2 L/s": keep a decimal on small flows.
static func _lps_text(q: float) -> String:
	return ("%.1f L/s" % q) if q < 10.0 else ("%.0f L/s" % q)


static func color_for(state: String) -> Color:
	match state:
		"generating": return C_GEN
		"primed": return C_PRIMED
		"fault": return C_FAULT
	return C_IDLE


func debug_summary() -> Dictionary:
	return {"state": _state, "text": _text, "color": _color,
			"bubbling": _bubbles != null and _bubbles.emitting}


func _refresh() -> void:
	if graph_item_id.is_empty():
		return
	var main := _main_node()
	if _sgv == null or not is_instance_valid(_sgv):
		_sgv = _system_graph_view(main)
	if _sgv == null:
		return
	var model = _sgv.get("model")
	if model == null or not model.has_method("get_item"):
		return
	var item: Dictionary = model.get_item(graph_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	_last_specs = specs
	var st := state_for(specs)
	_state = str(st["state"])
	_text = str(st["text"])
	_color = color_for(_state)
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(_color.r, _color.g, _color.b, 0.75)
		_ring_mat.emission = _color
	if _label != null:
		_label.text = _text
		_label.modulate = Color(_color.r, _color.g, _color.b).lerp(Color.WHITE, 0.55)
	if _bubbles != null:
		var broken := _state == "fault" and str(st["regime"]) != "cavitating" \
				and not bool(HydroSource.kind_meta(str(specs.get("turbine_kind", "siphon"))).get("has_penstock", false))
		if broken:
			_place_bubbles()
		_bubbles.emitting = broken

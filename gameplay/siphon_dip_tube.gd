class_name SiphonDipTube
extends Node3D

## The siphon turbine's DIP TUBE, in the world: ONE length of 6″ PVC dropping
## STRAIGHT DOWN from the machine's intake fitting into the pond, as long as
## the graph item's `dip_tube_length_m` says. Its mouth is the siphon's break
## level, so it is the one part of the machine the player tunes by eye
## against the water.
##
## HIDDEN BY DEFAULT (`specs.show_dip_tube`, the prop editor's and the Lab's
## "Show dip tube" toggle): the real tube is under water and the model does
## not carry one, so a permanently drawn tube read as clutter. When shown it
## hangs off the measured 6″ FITTING (`SiphonGeometry.intake_fitting`: the
## open end of the runner's leg, the same measurement the Lab's close-up
## makes), never off the `res_in_0` connection PORT — the port is where the
## 3D wire plugs in and the first cut hung an elbowed tube off it, which put
## the tube beside the machine instead of under its inlet.
##
## Attached by PlacedPropRuntime next to SiphonTurbineSpin for siphon-kind
## turbines. Polls the graph item on a 0.5 s cadence and rebuilds only when
## the length, bore, visibility or the fitting moved. Pure visual: the
## physics reads `dip_tube_length_m` itself.

const _POLL_S := 0.5
const _COLOR_PVC := Color(0.93, 0.93, 0.90, 1.0)
const _COLOR_MOUTH := Color(0.80, 0.80, 0.78, 1.0)

var graph_item_id: String = ""
var model_id: String = ""
var runner_node_name: String = ""
var _poll_acc: float = 999.0
var _sgv: Node = null
var _tube: MeshInstance3D = null
var _mouth: MeshInstance3D = null
var _last_key := ""
## Last placement, for the harness: world top / mouth, length, visibility.
var _last_top_w: Vector3 = Vector3.INF
var _last_mouth_w: Vector3 = Vector3.INF
var _last_len: float = 0.0
var _shown: bool = false


func configure(item_id: String, p_model_id: String = "", runner_name: String = "") -> void:
	graph_item_id = item_id
	model_id = p_model_id
	runner_node_name = runner_name


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	_poll_acc += delta
	if _poll_acc < _POLL_S:
		return
	_poll_acc = 0.0
	_refresh()


func _main_node() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree != null else null


func _system_graph_view(main: Node) -> Node:
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	if ui == null:
		return null
	return ui.get_node_or_null("SystemGraphView")


func _model_root() -> Node3D:
	var p := get_parent()
	if p == null:
		return null
	var mr := p.get_node_or_null("ModelRoot") as Node3D
	return mr if mr != null else (p as Node3D)


## The intake fitting in WORLD space, measured off the model (model-root
## frame carried through the root's global transform). Empty = no leg found.
func fitting_world() -> Dictionary:
	var root := _model_root()
	if root == null:
		return {}
	var fit := SiphonGeometry.fitting_for_model_root(root, model_id, runner_node_name)
	if fit.is_empty():
		return {}
	var gt := root.global_transform
	return {
		"pos": gt * (fit["pos"] as Vector3),
		"dir": (gt.basis * (fit["dir"] as Vector3)).normalized(),
		"radius": float(fit.get("radius", 0.076)) * gt.basis.get_scale().x,
	}


## For the harness: where the tube was last placed.
func debug_summary() -> Dictionary:
	return {
		"shown": _shown,
		"top": _last_top_w,
		"mouth": _last_mouth_w,
		"length_m": _last_len,
		"fitting": fitting_world(),
	}


func _refresh() -> void:
	if graph_item_id.is_empty():
		_hide_all()
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
		_hide_all()
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Only a SIPHON has a dip tube; a penstock kind on the same prop is fed by
	# its pipe. The kind selector flips this live.
	var kind := str(specs.get("turbine_kind", "siphon"))
	if bool(HydroSource.kind_meta(kind).get("has_penstock", false)):
		_hide_all()
		return
	if not bool(specs.get("show_dip_tube", false)):
		_hide_all()
		return
	var levels := SiphonHydraulics.resolve_siphon_levels(specs, float(item.get("elevation_m", NAN)))
	var module_m := float(levels.get("module_elev_m", NAN))
	var break_m := float(levels.get("siphon_break_m", NAN))
	var dip_len := float(specs.get("dip_tube_length_m", NAN))
	if is_nan(dip_len) or dip_len <= 0.0:
		dip_len = (module_m - break_m) if (not is_nan(module_m) and not is_nan(break_m)) else 1.0
	dip_len = clampf(dip_len, 0.1, 30.0)
	var bore := maxf(float(specs.get("intake_diameter_mm", 152.0)) / 1000.0, 0.03)
	var fit := fitting_world()
	if fit.is_empty():
		# No measurable leg (a stand-in box): hang it under the model's centre.
		var root := _model_root()
		if root == null:
			_hide_all()
			return
		fit = {"pos": root.global_position, "dir": Vector3.DOWN, "radius": bore * 0.5}
	var top_w: Vector3 = fit["pos"]
	var key := "%.3f|%.3f|%.2f|%.2f|%.2f" % [dip_len, bore, top_w.x, top_w.y, top_w.z]
	if key == _last_key and _shown:
		return
	_last_key = key
	_ensure_meshes()
	var inv := global_transform.affine_inverse()
	# ONE vertical cylinder from the fitting straight down. The tube starts a
	# hair inside the fitting so the joint reads as plumbing, not a gap.
	var mouth_w := top_w + Vector3.DOWN * dip_len
	var top_l := inv * (top_w + Vector3.UP * 0.01)
	var mouth_l := inv * mouth_w
	_place_cylinder(_tube, top_l, mouth_l, bore)
	# The mouth: a slightly wider ring so the end of the tube reads.
	_place_cylinder(_mouth, mouth_l + Vector3.UP * 0.03, mouth_l, bore * 1.12)
	_tube.visible = true
	_mouth.visible = true
	_shown = true
	_last_top_w = top_w
	_last_mouth_w = mouth_w
	_last_len = dip_len


func _ensure_meshes() -> void:
	if _tube != null:
		return
	_tube = _make_mesh(_COLOR_PVC)
	_mouth = _make_mesh(_COLOR_MOUTH)


func _make_mesh(col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 14
	cyl.rings = 1
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.55
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	return mi


## Seat a unit cylinder mesh between two local points at a given bore.
func _place_cylinder(mi: MeshInstance3D, a: Vector3, b: Vector3, bore: float) -> void:
	var cyl := mi.mesh as CylinderMesh
	var seg := b - a
	var len := seg.length()
	if len < 1e-4:
		mi.visible = false
		return
	cyl.height = len
	cyl.top_radius = bore * 0.5
	cyl.bottom_radius = bore * 0.5
	var y := seg / len
	var x := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	x = (x - y * x.dot(y)).normalized()
	var z := x.cross(y).normalized()
	mi.transform = Transform3D(Basis(x, y, z), (a + b) * 0.5)
	mi.visible = true


func _hide_all() -> void:
	_last_key = ""
	_shown = false
	for mi in [_tube, _mouth]:
		if mi != null:
			(mi as MeshInstance3D).visible = false

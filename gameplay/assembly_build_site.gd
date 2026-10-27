class_name AssemblyBuildSite
extends Node3D
## Per-part staging for ANY structure a crew builds or packs that has no
## builder of its own (the linkage and pallet-rack sites draw theirs): the
## kit's parts are LAID OUT on the ground beside the crate while the "lay
## out" phase runs, then SEATED one by one, bottom up, as the "assemble"
## phase is credited; a pack-up runs the same in reverse (strip takes them
## down onto the ground, pack takes them into the crate). What is drawn
## follows the project's own per-task fractions (NpcPopulationBridge.
## linkage_build_status `tasks`), eased between ticks, so the structure goes
## up exactly as fast as the crew's labour.
##
## Two ways of cutting a structure into parts:
##   - DESIGNER builders with an `assembly` build option (dome & zome,
##     toroid, flat-pack furniture): the site rebuilds the real node at a
##     quantised assembly fraction — their own ring-by-ring / part-by-part
##     drop-in animates it (`BUILDER_STEPS` rebuilds over a build).
##   - everything else (a GLB, a gantry, a procedural prop): the real model
##     is instantiated once and SPLIT into its mesh instances (one mesh with
##     several surfaces splits per surface), sorted bottom up; each part
##     lies flat on the ground in a yard beside the crate until its turn,
##     then glides onto its seat with a small lift.
##
## Record: `build_run = {mode: "labour", action: deploy|packup, iid,
## project_id}` on the prop (stamped by SiteDeployDirector), the same key
## the other sites read. The prop's own ModelRoot (the ghost) is hidden
## while the site owns the picture and shown again when it steps aside
## (no bridge, project cancelled).

const NODE_NAME := "AssemblyBuildSite"
const RECORD_KEY := "build_run"
const STATUS_EVERY_S := 0.25
const LABOUR_EASE_S := 1.2
const SITE_MARGIN_M := 14.0
## Designer builders: rebuilds over one build (a 216-plate dome is ~130 ms
## a rebuild; 24 of them over a build is a few frames of hitch, spread out).
const BUILDER_STEPS := 24
const REBUILD_MIN_S := 0.2
## Split mode: parts beyond this are folded into the last one.
const MAX_PARTS := 64
## The yard: parts lie in rows this far apart beside the crate.
const YARD_PITCH_M := 1.3
const YARD_COLS := 4
## A part lifts this high on its way from the yard to its seat.
const LIFT_M := 0.5
## Model ids whose builder takes an `assembly` option.
const BUILDER_MODELS := {
	"domelab_structure": true, "toroidlab_structure": true, "flatpack_furniture": true}

var _prop: PlacedProp = null
var _model: Node3D = null
var _rec: Dictionary = {}
var _run: Dictionary = {}
var _main: Node = null
var _action := SiteDeploySchedule.ACTION_DEPLOY
var _builder_mode := false
var _staged: Node3D = null          # builder mode: the rebuilt node
var _staged_step := -1
var _rebuild_cool := 0.0
var _parts: Array = []              # split mode: [{node, seat: Transform3D, yard: Transform3D, size}]
var _crate_local := Vector3.ZERO
var _status: Dictionary = {}
var _status_accum := 0.0
var _laid := 0.0
var _assembled := 0.0
var _laid_t := 0.0
var _assembled_t := 0.0
var _suspended := false
var _disposed := false


# ---------------------------------------------------------------------------
# Static API
# ---------------------------------------------------------------------------

## PlacedPropRuntime's hook: a non-linkage, non-rack prop under construction
## with a labour-mode build_run gets a site.
static func attach(prop: PlacedProp, rec: Dictionary) -> void:
	var mid := str(rec.get("model_id", ""))
	if mid == LinkageStructureBuilder.MODEL_ID or mid == PalletRackBuilder.MODEL_ID:
		return
	var run: Variant = rec.get(RECORD_KEY)
	if not (run is Dictionary) or str((run as Dictionary).get("mode", "")) != "labour":
		return
	var site := AssemblyBuildSite.new()
	site.name = NODE_NAME
	site.configure(rec)
	prop.add_child(site)


static func site_for(main: Node, prop_id: String) -> AssemblyBuildSite:
	var prop := PlacedPropService._find_prop_node(main, prop_id)
	return prop.get_node_or_null(NODE_NAME) as AssemblyBuildSite if prop != null else null


## What is laid out and what is seated for a project's task fractions
## (pure — the selftest pins it). Deploy: lay_out lays the parts in the
## yard, assemble seats them. Pack-up: strip takes them down to the yard,
## pack takes them into the crate. Both 0..1.
static func stage_state(tasks: Dictionary, action: String) -> Dictionary:
	if action == SiteDeploySchedule.ACTION_PACKUP:
		var strip := clampf(float(tasks.get("strip", 0.0)), 0.0, 1.0)
		var pack := clampf(float(tasks.get("pack", 0.0)), 0.0, 1.0)
		return {"laid": 1.0 - pack, "assembled": 1.0 - strip}
	var laid := clampf(float(tasks.get("lay_out", 0.0)), 0.0, 1.0)
	var asm := clampf(float(tasks.get("assemble", 0.0)), 0.0, 1.0)
	if tasks.has("finish") and float(tasks.get("finish", 0.0)) >= 1.0:
		asm = 1.0
	return {"laid": laid, "assembled": asm}


## Part i of n: 1 = seated, (0, 1) = on its way, 0 = still in the yard.
static func part_seat(i: int, n: int, assembled: float) -> float:
	if n <= 0:
		return 1.0
	return clampf(assembled * float(n) - float(i), 0.0, 1.0)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func configure(rec: Dictionary) -> void:
	_rec = rec.duplicate(true)
	_run = (rec.get(RECORD_KEY, {}) as Dictionary).duplicate(true)
	_action = str(_run.get("action", SiteDeploySchedule.ACTION_DEPLOY))
	_builder_mode = BUILDER_MODELS.has(str(rec.get("model_id", "")))


func _ready() -> void:
	_prop = get_parent() as PlacedProp
	_model = _prop.get_node_or_null("ModelRoot") as Node3D if _prop != null else null
	if _model == null or _run.is_empty():
		set_process(false)
		return
	_main = get_tree().current_scene
	transform = _model.transform
	var crate := _prop.get_node_or_null("KitCrate") as Node3D
	if crate != null:
		_crate_local = _model.transform.affine_inverse() * crate.position
	else:
		_crate_local = Vector3(maxf(_prop.get_local_pick_radius(), 1.0) + 2.5, 0.0, 0.0)
	if not _builder_mode:
		_build_parts()
	_poll_status()
	_laid_t = _laid
	_assembled_t = _assembled
	_update(0.0)


func _exit_tree() -> void:
	if not _disposed and is_instance_valid(_model):
		_show_model()


## Step aside: the prop's own model comes back — unless it is still the
## construction ghost (a deploy / pack-up running), which reads as a second,
## finished structure standing where the crew is working; then the kit crate
## (if any) is all that stands there.
func _show_model() -> void:
	var uc := is_instance_valid(_prop) and bool(_prop.get_meta("under_construction", false))
	_model.visible = not uc
	var crate := _prop.get_node_or_null("KitCrate") as Node3D if is_instance_valid(_prop) else null
	if crate != null:
		crate.visible = true


func owns_visuals() -> bool:
	return not _disposed and not _suspended


func dispose() -> void:
	_disposed = true
	set_process(false)
	if is_instance_valid(_model):
		_show_model()
	if is_instance_valid(_staged):
		_staged.visible = false
	for p in _parts:
		var n: Node3D = p["node"]
		if is_instance_valid(n):
			n.visible = false


func progress_line() -> String:
	if _action == SiteDeploySchedule.ACTION_PACKUP:
		return "Taking down · %d %% down · %d %% packed" % [int(round((1.0 - _assembled) * 100.0)),
			int(round((1.0 - _laid) * 100.0))]
	return "Building · %d %% laid out · %d %% up" % [int(round(_laid * 100.0)), int(round(_assembled * 100.0))]


# ---------------------------------------------------------------------------
# Labour
# ---------------------------------------------------------------------------

func _bridge() -> Object:
	var sgv: Object = ServiceLocator.graph()
	if sgv == null and _main != null:
		sgv = _main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


func _poll_status() -> void:
	var bridge := _bridge()
	if bridge == null or not bridge.has_method("linkage_build_status"):
		_status = {"found": false}
		return
	var c3 := global_transform.origin if is_inside_tree() else Vector3.ZERO
	_status = bridge.call("linkage_build_status", str(_run.get("iid", "")), str(_run.get("project_id", "")),
		Vector2(c3.x, c3.z), maxf(_prop.get_local_pick_radius(), 2.0) + SITE_MARGIN_M)
	if not bool(_status.get("found", false)):
		return
	match str(_status.get("state", "")):
		"done":
			var end := _action == SiteDeploySchedule.ACTION_DEPLOY
			_laid = 1.0 if end else 0.0
			_assembled = 1.0 if end else 0.0
		"active":
			var st := stage_state(_status.get("tasks", {}), _action)
			_laid = float(st["laid"])
			_assembled = float(st["assembled"])
		_:
			dispose()


func _process(delta: float) -> void:
	if _disposed or not is_instance_valid(_model):
		set_process(false)
		return
	_status_accum += delta
	if _status_accum >= STATUS_EVERY_S:
		_status_accum = 0.0
		_poll_status()
		if _disposed:
			return
	var k := 1.0 - exp(-maxf(delta, 0.0) / LABOUR_EASE_S)
	_laid_t += (_laid - _laid_t) * k
	_assembled_t += (_assembled - _assembled_t) * k
	if absf(_laid - _laid_t) < 0.002:
		_laid_t = _laid
	if absf(_assembled - _assembled_t) < 0.002:
		_assembled_t = _assembled
	_rebuild_cool = maxf(_rebuild_cool - delta, 0.0)
	_update(delta)


func _update(_delta: float) -> void:
	transform = _model.transform
	if not bool(_status.get("found", false)):
		if not _suspended:
			_suspended = true
			_show_model()
			if is_instance_valid(_staged):
				_staged.visible = false
			for p in _parts:
				(p["node"] as Node3D).visible = false
		return
	if _suspended:
		_suspended = false
	_model.visible = false
	if _builder_mode:
		_update_builder()
	else:
		_update_parts()


# ---------------------------------------------------------------------------
# Designer builders (assembly option)
# ---------------------------------------------------------------------------

func _update_builder() -> void:
	var step := int(round(_assembled_t * float(BUILDER_STEPS)))
	if step == _staged_step and is_instance_valid(_staged):
		return
	if _rebuild_cool > 0.0 and is_instance_valid(_staged) and step != BUILDER_STEPS and step != 0:
		return
	_rebuild_cool = REBUILD_MIN_S
	_staged_step = step
	if is_instance_valid(_staged):
		_staged.queue_free()
	var a := float(step) / float(BUILDER_STEPS)
	_staged = _build_staged(a)
	if _staged == null:
		return
	_staged.name = "Staged"
	add_child(_staged)


func _build_staged(assembly: float) -> Node3D:
	var mid := str(_rec.get("model_id", ""))
	var opts := {"assembly": assembly}
	if mid == DomeLabBuilder.MODEL_ID:
		return DomeLabBuilder.build_node(_rec.get("domelab_spec", {}) as Dictionary, "Staged", opts)
	if mid == ToroidLabBuilder.MODEL_ID:
		return ToroidLabBuilder.build_node(_rec.get("toroid_spec", {}) as Dictionary, "Staged", opts)
	if mid == FlatpackBuilder.MODEL_ID:
		return FlatpackBuilder.build_node(_rec.get("flatpack_spec", {}) as Dictionary, "Staged", opts)
	return null


# ---------------------------------------------------------------------------
# Split mode (any other model)
# ---------------------------------------------------------------------------

## Instantiate the real model once and cut it into parts: every
## MeshInstance3D (a lone mesh with several surfaces splits per surface),
## each re-parented under the site with its model-relative transform, sorted
## bottom up with its yard spot beside the crate.
func _build_parts() -> void:
	var model := ModelCatalog.instantiate(str(_rec.get("model_id", "")), PlacedPropRuntime.model_extras(_rec))
	if model == null:
		return
	PlacedPropRuntime._disable_embedded_physics(model)
	var found: Array = []   # [{mesh, xf, mats: [Material], override}]
	_collect_meshes(model, Transform3D.IDENTITY, found)
	if found.size() == 1 and (found[0]["mesh"] as Mesh).get_surface_count() > 1:
		found = _split_surfaces(found[0] as Dictionary)
	model.queue_free()
	if found.is_empty():
		return
	# Bottom up, then along X — a roof never lands before its posts.
	for f in found:
		var fd := f as Dictionary
		var bb: AABB = (fd["xf"] as Transform3D) * ((fd["mesh"] as Mesh).get_aabb())
		fd["aabb"] = bb
		fd["key"] = bb.position.y + bb.size.y * 0.5 + 0.01 * (bb.position.x + bb.size.x * 0.5)
	found.sort_custom(func(a, b) -> bool: return float(a["key"]) < float(b["key"]))
	if found.size() > MAX_PARTS:
		found = found.slice(0, MAX_PARTS)
	var holder := Node3D.new()
	holder.name = "Parts"
	add_child(holder)
	for i in found.size():
		var fd := found[i] as Dictionary
		var mi := MeshInstance3D.new()
		mi.mesh = fd["mesh"]
		mi.name = "Part%d" % i
		var mats: Array = fd.get("mats", [])
		for s in mats.size():
			if mats[s] != null:
				mi.set_surface_override_material(s, mats[s])
		if fd.get("override", null) != null:
			mi.material_override = fd["override"]
		var seat: Transform3D = fd["xf"]
		var bb: AABB = fd["aabb"]
		# The yard spot: rows beside the crate, the part lying with its
		# lowest point on the ground, upright as it will sit.
		var col := i % YARD_COLS
		var row := i / YARD_COLS
		var yard_pos := _crate_local + Vector3(1.8 + float(col) * YARD_PITCH_M, 0.0,
			-1.5 * YARD_PITCH_M + float(row) * YARD_PITCH_M)
		var local_bb: AABB = (fd["mesh"] as Mesh).get_aabb()
		var yard := Transform3D(seat.basis, yard_pos - seat.basis * Vector3(local_bb.get_center().x,
			local_bb.position.y, local_bb.get_center().z))
		mi.transform = yard
		mi.visible = false
		holder.add_child(mi)
		_parts.append({"node": mi, "seat": seat, "yard": yard, "size": bb.size})


func _collect_meshes(node: Node, xf: Transform3D, out: Array) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		var mats: Array = []
		for s in mi.mesh.get_surface_count():
			mats.append(mi.get_surface_override_material(s))
		out.append({"mesh": mi.mesh, "xf": here, "mats": mats, "override": mi.material_override})
	for c in node.get_children():
		if c is Node3D and not (c as Node3D).visible:
			continue   # an exporter's leftovers, a hidden LOD
		_collect_meshes(c, here, out)


func _split_surfaces(fd: Dictionary) -> Array:
	var mesh: Mesh = fd["mesh"]
	var out: Array = []
	for s in mesh.get_surface_count():
		var am := ArrayMesh.new()
		var arrays := mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = (fd["mats"] as Array)[s]
		if mat == null:
			mat = mesh.surface_get_material(s)
		out.append({"mesh": am, "xf": fd["xf"], "mats": [mat], "override": fd.get("override", null)})
	return out


func _update_parts() -> void:
	var n := _parts.size()
	for i in n:
		var p: Dictionary = _parts[i]
		var node: Node3D = p["node"]
		var laid := clampf(_laid_t * float(n) - float(i), 0.0, 1.0)
		var seat := part_seat(i, n, _assembled_t)
		if laid <= 0.0 and seat <= 0.0:
			node.visible = false
			continue
		node.visible = true
		if seat >= 1.0:
			node.transform = p["seat"]
			continue
		if seat <= 0.0:
			# In the yard: a part just laid out settles down onto the ground.
			var y: Transform3D = p["yard"]
			node.transform = Transform3D(y.basis, y.origin + Vector3(0.0, LIFT_M * (1.0 - laid), 0.0))
			continue
		# On its way: yard -> seat, eased, with a lift in the middle.
		var k := seat * seat * (3.0 - 2.0 * seat)
		var a: Transform3D = p["yard"]
		var b: Transform3D = p["seat"]
		var pos := a.origin.lerp(b.origin, k) + Vector3(0.0, LIFT_M * sin(k * PI), 0.0)
		# The yard pose shares the seat's basis (a part lies as it will sit),
		# so only the position moves. Never slerp these bases: an inch-unit
		# GLB part carries a 0.0254 scale, and Basis.slerp refuses anything
		# that is not orthonormal (200 engine errors a build, measured).
		node.transform = Transform3D(b.basis, pos)

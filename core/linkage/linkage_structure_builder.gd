class_name LinkageStructureBuilder
extends Node3D
## Procedural 3D renderer for a solved LinkageLab scissor structure.
##
## Consumes LinkageSolver frames (inches, Y-up) and renders them in METRES
## (x 0.0254) as MultiMeshes so fold-angle scrubbing only rewrites per-instance
## transforms — no mesh rebuild per frame:
##   - Beams: one MultiMesh of unit boxes (basis columns = axis_x*w, axis_y*t,
##     axis_z*len — exactly the Beam3D frame from the solver).
##   - Brackets: one MultiMesh of a unit U-channel ArrayMesh (simplified
##     visual; x = bolt axis/width, y = opening/height, z = beam axis/depth).
##   - Bolts: shaft + head MultiMeshes of unit cylinders.
##
## Local origin: ground center — the structure's lowest beam corner sits at
## local Y = 0 (matches how imported GLB props seat in the world today).
## Beam/bracket/bolt COUNTS are a function of params only (not fold angle),
## so set_fold_angle() never reallocates.

const INCH_TO_M := 0.0254
const WOOD_COLOR := Color(238.0 / 255.0, 191.0 / 255.0, 161.0 / 255.0)
const BRACKET_COLOR := Color(0.62, 0.64, 0.67)
const BOLT_COLOR := Color(0.35, 0.36, 0.38)
const PANEL_FRAME_COLOR := Color(0.12, 0.12, 0.14)
const PANEL_CELL_COLOR := Color(25.0 / 255.0, 50.0 / 255.0, 120.0 / 255.0)

## ModelCatalog procedural id (world placement via PlacedPropService).
const MODEL_ID := "linkage_structure"

var params: LinkageParams = LinkageParams.new()

## When true, rebuild() maintains a hidden per-beam MeshInstance3D
## ("CollisionMesh") that PlacedProp.setup_collision() / pick-AABB /
## ModelCatalog.mesh_metrics can consume — those APIs only see
## MeshInstance3D geometry and this renderer is otherwise pure MultiMesh.
## Off by default (the designer studio doesn't need it).
var collision_mesh_enabled := false

var _beam_mm: MultiMeshInstance3D
var _bracket_mm: MultiMeshInstance3D
var _bolt_mm: MultiMeshInstance3D
var _bolt_head_mm: MultiMeshInstance3D
var _panel_mm: MultiMeshInstance3D
var _support_mm: MultiMeshInstance3D

var _last_frame: Dictionary = {}
var _last_support: Array = []
var _last_panels: Array = []
var _fold_angle := -1.0
var _closed_angle_cache := NAN
var _closed_angle_key := ""
var _min_fold_cache := NAN
var _min_fold_key := ""
var _packed_cache: Dictionary = {}
var _packed_key := ""

var _wood_mat: StandardMaterial3D
var _bracket_mat: StandardMaterial3D
var _bolt_mat: StandardMaterial3D
var _panel_mat: StandardMaterial3D
## Translucent variants for the hardware editor's part view, keyed on source
## material + alpha. See `set_ghost_alpha`.
var _ghost_mats: Dictionary = {}
var _ghost_alpha := 1.0
## Progressive-construction fractions per element class (Site Projects).
## Empty = feature off, everything visible. See set_build_progress.
var _build_progress: Dictionary = {}


func _ready() -> void:
	_ensure_materials()
	if _fold_angle < 0.0:
		set_fold_angle(params.fold_angle)


func _ensure_materials() -> void:
	if _wood_mat != null:
		return
	# Shared procedural PBR (see core/structure_materials.gd). World-space triplanar
	# because the beams are MultiMesh unit boxes scaled per instance — object-space
	# would stretch one texel across a long arm; world-space keeps a consistent grain
	# density across every member. Brackets/bolts are now low-/rough-metallic so they
	# no longer collapse to black when a fold self-shadows them (the old 0.8–0.9
	# metallic with no reflection source read as flat dark). CULL_DISABLED is retained
	# inside the factory for the mirrored-basis winding case documented previously.
	_wood_mat = StructureMaterials.make(StructureMaterials.Kind.WOOD, WOOD_COLOR, true)
	_bracket_mat = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, BRACKET_COLOR, true)
	_bolt_mat = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, BOLT_COLOR, true)
	_panel_mat = StructureMaterials.make(StructureMaterials.Kind.PANEL, PANEL_CELL_COLOR, true)


## Factory for world placement (ModelCatalog procedural branch): builds a
## grounded, collision-capable structure node from a v30 config dict.
static func build_node(spec: Dictionary = {}, node_name: String = "LinkageStructure") -> Node3D:
	var builder := LinkageStructureBuilder.new()
	builder.name = node_name
	builder.collision_mesh_enabled = true
	var p := LinkageParams.new()
	if not spec.is_empty():
		p.from_config(spec)
	builder.set_params(p)
	builder.set_meta("linkage_spec", p.to_config())
	return builder


## Current design as a v30 config dict (foldAngle reflects the live fold).
func current_config() -> Dictionary:
	return params.to_config()


## Assign new parameters and rebuild everything (counts may change).
func set_params(p: LinkageParams) -> void:
	params = p
	rebuild()


## Full rebuild: reallocate MultiMeshes for the current params + fold angle.
func rebuild() -> void:
	_ensure_materials()
	_free_multimeshes()
	_fold_angle = clampf(params.fold_angle, LinkageKinematics.MIN_FOLD_ANGLE, LinkageKinematics.MAX_FOLD_ANGLE)
	var frame := LinkageSolver.solve(params, _fold_angle)
	_last_frame = frame
	_compute_extras(frame)
	_allocate_from_frame(frame)
	_write_frame_transforms(frame)
	if collision_mesh_enabled:
		refresh_collision_mesh()


## Re-solve at a new fold angle and update instance transforms in place.
## Support/RCP/panel visibility angles can change counts mid-fold, in which
## case the affected MultiMeshes reallocate (still no ArrayMesh rebuild).
func set_fold_angle(angle_rad: float) -> void:
	_ensure_materials()
	var clamped := clampf(angle_rad, LinkageKinematics.MIN_FOLD_ANGLE, LinkageKinematics.MAX_FOLD_ANGLE)
	_fold_angle = clamped
	params.fold_angle = clamped
	var frame := LinkageSolver.solve(params, clamped)
	_last_frame = frame
	_compute_extras(frame)
	if _beam_mm == null or _count_mismatch(frame):
		_free_multimeshes()
		_allocate_from_frame(frame)
	_write_frame_transforms(frame)


## Support beams (visibility-gated by fold angle) + solar panels for a frame.
func _compute_extras(frame: Dictionary) -> void:
	_last_support = LinkageGeometry.support_beams(frame, params, _fold_angle)
	_last_panels = LinkageGeometry.solar_panels(frame, params) if _panels_visible() else []


## Panel visibility gate — port of the buildLinkageGeometry rule: user angle
## when set, else "at the closed/deploy angle" (closed − 2°).
func _panels_visible() -> bool:
	if not bool(params.solar_panels["enabled"]):
		return false
	var min_rad := deg_to_rad(params.panels_visible_angle) if params.panels_visible_angle >= 0.0 \
		else closed_angle() - deg_to_rad(2.0)
	return _fold_angle >= min_rad


func get_fold_angle() -> float:
	return _fold_angle


func last_frame() -> Dictionary:
	return _last_frame


func last_support_beams() -> Array:
	return _last_support


func last_panels() -> Array:
	return _last_panels


## Ring-closure (deployed) angle for the current params, cached like the web app.
func closed_angle() -> float:
	var key := _kinematics_key()
	if _closed_angle_key != key or is_nan(_closed_angle_cache):
		_closed_angle_cache = LinkageKinematics.optimal_closed_angle(params)
		_closed_angle_key = key
	return _closed_angle_cache


## Minimum (stowed) fold angle: user override or V-beam contact, cached.
func min_fold_angle() -> float:
	if params.min_fold_angle_deg >= 0.0:
		return deg_to_rad(params.min_fold_angle_deg)
	var key := _kinematics_key() + "|%s|%s|%s|%s" % [params.v_beam_outer_w, params.v_beam_outer_t, params.v_beam_w, params.v_beam_t]
	if _min_fold_key != key or is_nan(_min_fold_cache):
		_min_fold_cache = LinkageKinematics.min_fold_angle_v_overlap(params)
		_min_fold_key = key
	return _min_fold_cache


func _kinematics_key() -> String:
	return "%d|%s|%s|%s|%s|%s|%s" % [params.modules, params.pivot_pct, params.hoberman_ang, params.pivot_ang, params.h_length_ft, params.offset_top_in, params.offset_bot_in]


## Packed ("shipping") spec for the CURRENT design — PACKING_PLAN.md Phase 0.
## Cached on everything but the live fold angle (the envelope is solved at the
## stow angle regardless), because _update_stats calls this on every fold tick.
func packed_spec() -> Dictionary:
	var cfg := params.to_config()
	cfg.erase("foldAngle")
	var key := str(cfg.hash())
	if _packed_key != key or _packed_cache.is_empty():
		_packed_cache = packed_spec_for(params)
		_packed_key = key
	return _packed_cache


## Packed spec computed from a LinkageParams alone (static, offline-testable).
## The envelope is solved at the EFFECTIVE minimum fold angle (user override
## else V-beam contact — see PACKING_PLAN.md Phase 0.5), never at whatever
## fold the slider happens to show, so an impossible over-fold can't shrink
## the shipping dims. Covers the structure only: beams + brackets + bolts +
## support beams (which detach and bundle alongside the folded ring). Solar
## panels are deliberately EXCLUDED — they pack as their own stack (their
## count/weight comes from deployed_panel_summary), which is exactly the
## Phase 3 "boxes within boxes" split.
static func packed_spec_for(p: LinkageParams) -> Dictionary:
	# Densities + the per-part volume formulas live in LinkageBom so the BOM and
	# the shipping spec can never disagree about what a bracket weighs. This
	# function reduces them to one scalar; LinkageBom keeps the itemization.
	var in3_to_m3 := LinkageBom.IN3_TO_M3
	var stow: float = maxf(LinkageKinematics.effective_min_fold_angle(p),
		LinkageKinematics.MIN_FOLD_ANGLE)
	var frame: Dictionary = LinkageSolver.solve(p, stow)
	var beams: Array = frame.get("beams", [])
	if beams.is_empty():
		return {}
	# Envelope: AABB over folded beam corners (+1.5" bracket protrusion).
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var wood_in3 := 0.0
	for beam in beams:
		for c in beam["corners"]:
			mn = mn.min(c)
			mx = mx.max(c)
		wood_in3 += float(beam["w"]) * float(beam["t"]) \
			* (beam["p1"] as Vector3).distance_to(beam["p2"] as Vector3)
	var margin := 1.5
	var size_m := (mx - mn + Vector3.ONE * 2.0 * margin) * INCH_TO_M
	# Support beams ship in the same bundle: size + count from the deployed
	# frame (they are visibility-gated away at stow angles).
	var closed: float = LinkageKinematics.optimal_closed_angle(p)
	var deployed: Dictionary = LinkageSolver.solve(p, closed)
	for sb in LinkageGeometry.support_beams(deployed, p, closed):
		wood_in3 += float(sb["w"]) * float(sb["t"]) \
			* (sb["p1"] as Vector3).distance_to(sb["p2"] as Vector3)
	var mass := wood_in3 * in3_to_m3 * PackedSpec.WOOD_KG_M3
	# Brackets: simplified U-channel steel volume (2 walls + base).
	for br in frame.get("brackets", []):
		mass += LinkageBom.bracket_mass_kg(
			float(br.get("width", p.bracket_width)),
			float(br.get("depth", p.bracket_depth)),
			float(br.get("actual_height", p.bracket_height)),
			p.bracket_wall_thickness)
	# Bolts: shaft volume ×1.5 for head/nut/washers. Stack washers are
	# deliberately NOT counted here — they are a BOM line only, and adding
	# them would move every pinned shipping mass in packing_selftest.
	for bolt in frame.get("bolts", []):
		mass += LinkageBom.bolt_mass_kg(
			float(bolt.get("radius", p.bolt_diameter / 2.0)) * 2.0,
			float(bolt.get("length", 3.0)))
	return PackedSpec.normalize({
		"w_m": size_m.x, "d_m": size_m.y, "h_m": size_m.z,
		"mass_kg": mass, "form": "folded", "source": "computed",
	})


## Stats for the designer HUD (imperial from the frame; metric convenience).
func get_stats() -> Dictionary:
	if _last_frame.is_empty():
		return {}
	var beams: Array = _last_frame["beams"]
	return {
		"beam_count": beams.size(),
		"bracket_count": (_last_frame["brackets"] as Array).size(),
		"bolt_count": (_last_frame["bolts"] as Array).size(),
		"support_beam_count": _last_support.size(),
		"panel_count": _last_panels.size(),
		"panel_watts": LinkageGeometry.total_watts(_last_panels),
		"module_count": params.modules,
		"max_height_in": float(_last_frame["max_height"]),
		"max_diameter_in": float(_last_frame["max_rad"]) * 2.0,
		"max_height_m": float(_last_frame["max_height"]) * INCH_TO_M,
		"max_diameter_m": float(_last_frame["max_rad"]) * 2.0 * INCH_TO_M,
		"fold_angle_deg": rad_to_deg(_fold_angle),
	}


## Panel count + total rated watts at the DEPLOYED (closed) angle regardless
## of the current fold state — the Phase 6 solar/graph handoff numbers.
## Also carries per-panel electrical specs (from the active panel section),
## panel plan dimensions in metres, and the average panel normal (builder
## LOCAL space) so the graph seeder can derive real tilt/azimuth from the
## deployed geometry instead of the web app's gridRotation heuristic.
func deployed_panel_summary() -> Dictionary:
	var empty := {"count": 0, "watts": 0.0, "watts_per_panel": 0.0,
		"avg_normal": Vector3.UP}
	if not bool(params.solar_panels["enabled"]):
		return empty
	var deployed_frame := LinkageSolver.solve(params, closed_angle())
	var panels := LinkageGeometry.solar_panels(deployed_frame, params)
	if panels.is_empty():
		return empty
	var total := LinkageGeometry.total_watts(panels)
	var normal_sum := Vector3.ZERO
	for panel in panels:
		normal_sum += (panel["axis_y"] as Vector3).normalized()
	# Arch mode places panels on wall faces (side section); cylinder mode on
	# the top canopy (top section) — electrical specs come from that section.
	var sec: Dictionary = params.solar_panels["side_panels"] \
		if params.orientation == "vertical" else params.solar_panels["top_panels"]
	return {
		"count": panels.size(),
		"watts": total,
		"watts_per_panel": total / float(panels.size()),
		"avg_normal": (normal_sum / float(panels.size())).normalized(),
		"voc": float(sec["voc"]),
		"vmp": float(sec["vmp"]),
		"isc": float(sec["isc"]),
		"imp": float(sec["imp"]),
		"panel_w_m": float(sec["panel_width"]) * INCH_TO_M,
		"panel_h_m": float(sec["panel_length"]) * INCH_TO_M,
	}


## Tilt (deg from horizontal) + compass azimuth (deg from north, clockwise —
## matches CelestialClock's sun convention: north = -Z, east = +X) for a
## WORLD-space panel normal. Near-flat panels have no meaningful azimuth and
## default to 180 (south).
static func orientation_from_normal(n_world: Vector3) -> Dictionary:
	var n := n_world.normalized()
	var tilt := rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
	var az := 180.0
	if Vector2(n.x, n.z).length() > 1e-4:
		az = fposmod(rad_to_deg(atan2(n.x, -n.z)), 360.0)
	return {"tilt_deg": tilt, "azimuth_deg": az}


## Local-space AABB of the current frame (metres) — for camera fitting.
func frame_aabb() -> AABB:
	if _last_frame.is_empty():
		return AABB()
	var beams: Array = _last_frame["beams"]
	if beams.is_empty():
		return AABB()
	var ground := _ground_offset_m()
	var first: Vector3 = (beams[0]["corners"] as Array)[0] * INCH_TO_M + Vector3(0, ground, 0)
	var aabb := AABB(first, Vector3.ZERO)
	for b in beams + _last_support:
		for c in b["corners"]:
			aabb = aabb.expand((c as Vector3) * INCH_TO_M + Vector3(0, ground, 0))
	return aabb


# ---------------------------------------------------------------------------
# MultiMesh management
# ---------------------------------------------------------------------------

func _free_multimeshes() -> void:
	# free() (not queue_free) so node-name lookups and reallocation within the
	# same frame never hit a stale queued-for-deletion sibling.
	for mm in [_beam_mm, _bracket_mm, _bolt_mm, _bolt_head_mm, _panel_mm, _support_mm]:
		if mm != null and is_instance_valid(mm):
			mm.free()
	_beam_mm = null
	_bracket_mm = null
	_bolt_mm = null
	_bolt_head_mm = null
	_panel_mm = null
	_support_mm = null


func _count_mismatch(frame: Dictionary) -> bool:
	if _beam_mm == null or _beam_mm.multimesh == null:
		return true
	if _beam_mm.multimesh.instance_count != (frame["beams"] as Array).size():
		return true
	var bracket_count := (frame["brackets"] as Array).size()
	if (_bracket_mm == null) != (bracket_count == 0):
		return true
	if _bracket_mm != null and _bracket_mm.multimesh.instance_count != bracket_count:
		return true
	var bolt_count := (frame["bolts"] as Array).size()
	if (_bolt_mm == null) != (bolt_count == 0):
		return true
	if _bolt_mm != null and _bolt_mm.multimesh.instance_count != bolt_count:
		return true
	var support_count := _last_support.size()
	if (_support_mm == null) != (support_count == 0):
		return true
	if _support_mm != null and _support_mm.multimesh.instance_count != support_count:
		return true
	var panel_count := _last_panels.size()
	if (_panel_mm == null) != (panel_count == 0):
		return true
	if _panel_mm != null and _panel_mm.multimesh.instance_count != panel_count:
		return true
	return false


## Render the whole frame translucent, for the hardware editor's part view.
##
## A joint is INSIDE the members it clamps, so at the range you need to read a
## bolt stack the timber is simply in the way — the web app fades every beam
## within 36" of the focus for exactly this reason (`HW_DETAIL_BEAM_RADIUS`,
## scene-render.js:9). Fading the whole frame instead of a radius costs nothing
## here and needs no per-instance colour: these are MultiMeshes of unit boxes,
## so a distance-graded fade would mean a custom shader for a preview.
##
## The ghost materials are DUPLICATES. The originals come from
## `core/structure_materials.gd` and are shared with every structure in the
## game, so tinting them in place would ghost the props standing in the world.
## `alpha >= 1.0` restores the originals.
func set_ghost_alpha(alpha: float) -> void:
	_ensure_materials()
	_ghost_alpha = alpha
	var solid := alpha >= 0.999
	for pair in [[_beam_mm, _wood_mat], [_panel_mm, _panel_mat],
			[_support_mm, _wood_mat], [_bracket_mm, _bracket_mat],
			[_bolt_mm, _bolt_mat], [_bolt_head_mm, _bolt_mat]]:
		var inst := pair[0] as MultiMeshInstance3D
		if inst == null:
			continue
		var base := pair[1] as StandardMaterial3D
		inst.material_override = base if solid else _ghost_of(base, alpha)


## Progressive-construction reveal (Site Projects): the fraction of each
## element class currently "built", {beams, brackets, bolts, supports,
## panels: 0..1}. Missing keys default to 1 (shown); an EMPTY dict clears the
## feature (everything visible — the ordinary fully-built state). Same
## mechanism as the CNC print ghost (`cnc_machine_runtime._update_print_ghost`):
## `visible_instance_count` reveals a prefix of each MultiMesh in its write
## order, which for beams is the solver's per-module emission order — the ring
## grows module by module. Pair with set_ghost_alpha for the firming-up read.
func set_build_progress(p: Dictionary) -> void:
	_build_progress = p.duplicate(true)
	_apply_build_progress()


func build_progress() -> Dictionary:
	return _build_progress


## Elements per second the reveal animation may move, per element class. The
## FLOOR is what makes single panels readable — 18 panels at 2.5/s is a
## seven-second sweep where each one visibly lands (or leaves) on its own;
## the count/10 term keeps a 200-beam ring from taking a minute.
const REVEAL_MIN_PER_S := 2.5

## mm name -> currently DISPLAYED element count (float — the animator's
## position between integers). Progress updates land in chunks (a labour
## credit is a tick, not a panel), so the displayed count walks toward the
## target one element at a time instead of jumping four panels per credit.
var _reveal_shown: Dictionary = {}


func _progress_pairs() -> Array:
	return [[_beam_mm, "beams"], [_bracket_mm, "brackets"],
		[_bolt_mm, "bolts"], [_bolt_head_mm, "bolts"],
		[_support_mm, "supports"], [_panel_mm, "panels"]]


func _apply_build_progress() -> void:
	for pair in _progress_pairs():
		var inst := pair[0] as MultiMeshInstance3D
		if inst == null or inst.multimesh == null:
			continue
		if _build_progress.is_empty():
			inst.multimesh.visible_instance_count = -1
			_reveal_shown.erase(inst.name)
			continue
		var frac := clampf(float(_build_progress.get(pair[1], 1.0)), 0.0, 1.0)
		var target := int(round(frac * float(inst.multimesh.instance_count)))
		# Offline / not-yet-in-tree contexts snap (selftests read the count
		# straight back, and a cold load must not animate a standing frame out
		# of nothing — construction props are built OFF-tree, so a restore
		# always lands here).
		if not is_inside_tree():
			inst.multimesh.visible_instance_count = target
			_reveal_shown[inst.name] = float(target)
		elif not _reveal_shown.has(inst.name):
			# A LIVE builder meeting this element for the first time — the
			# post-unpack fresh builder, or a mid-build reallocation minting
			# the panel MultiMesh. A COMPLETE element (frac ~1, e.g. the beams
			# the deploy sweep just raised) snaps: it is not under
			# construction. An INCOMPLETE one starts at ZERO and walks up via
			# _process — this is what makes panels land one at a time during
			# the build instead of popping in at the accrued fraction (the
			# fresh MultiMesh's -1 default meant they ALL showed until the
			# target next moved).
			if frac >= 0.999:
				inst.multimesh.visible_instance_count = target
				_reveal_shown[inst.name] = float(target)
			else:
				inst.multimesh.visible_instance_count = 0
				_reveal_shown[inst.name] = 0.0
	if is_inside_tree() and not _build_progress.is_empty():
		set_process(true)


## Softest gap between reveal clicks — beams animate at up to ~15/s, and a
## click per beam at that rate is a machine gun, not carpentry.
const REVEAL_CLICK_GAP_S := 0.12
var _click_cooldown := 0.0


func _process(delta: float) -> void:
	if _build_progress.is_empty():
		set_process(false)
		return
	_click_cooldown = maxf(_click_cooldown - delta, 0.0)
	var busy := false
	var landed := false
	for pair in _progress_pairs():
		var inst := pair[0] as MultiMeshInstance3D
		if inst == null or inst.multimesh == null:
			continue
		var count := float(inst.multimesh.instance_count)
		var frac := clampf(float(_build_progress.get(pair[1], 1.0)), 0.0, 1.0)
		var target := roundf(frac * count)
		var shown := float(_reveal_shown.get(inst.name, target))
		if absf(shown - target) < 0.001:
			continue
		busy = true
		shown = move_toward(shown, target,
			delta * maxf(REVEAL_MIN_PER_S, count / 10.0))
		_reveal_shown[inst.name] = shown
		var vis := int(roundf(shown))
		if vis != inst.multimesh.visible_instance_count:
			landed = true
		inst.multimesh.visible_instance_count = vis
	# A soft click when an element actually lands (or leaves) — the sound is
	# what makes the one-at-a-time reveal read as work being done rather than
	# a counter ticking. Same quiet tier as the graph's wire click.
	if landed and _click_cooldown <= 0.0:
		_click_cooldown = REVEAL_CLICK_GAP_S
		var sfx := get_node_or_null("/root/UiSound")
		if sfx != null and sfx.has_method("play_ui"):
			sfx.call("play_ui", "connect", 80)
	if not busy:
		set_process(false)


func _ghost_of(base: StandardMaterial3D, alpha: float) -> StandardMaterial3D:
	if base == null:
		return null
	var key := "%s|%.2f" % [str(base.get_instance_id()), alpha]
	var cached = _ghost_mats.get(key)
	if cached is StandardMaterial3D:
		return cached
	var m := base.duplicate() as StandardMaterial3D
	# Depth pre-pass, not plain alpha: a beam is a closed box, and without it
	# every internal face stacks up into a milky slab you can see even less
	# through than the solid timber (the same trap the hardware timber hit).
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	var c := m.albedo_color
	c.a = alpha
	m.albedo_color = c
	_ghost_mats[key] = m
	return m


func _make_mm_instance(mesh: Mesh, count: int, material: StandardMaterial3D, mm_name: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	var inst := MultiMeshInstance3D.new()
	inst.name = mm_name
	inst.multimesh = mm
	inst.material_override = material
	add_child(inst)
	return inst


func _allocate_from_frame(frame: Dictionary) -> void:
	var beam_count := (frame["beams"] as Array).size()
	if beam_count > 0:
		_beam_mm = _make_mm_instance(BoxMesh.new(), beam_count, _wood_mat, "Beams")
	var bracket_count := (frame["brackets"] as Array).size()
	if bracket_count > 0:
		_bracket_mm = _make_mm_instance(_build_bracket_mesh(), bracket_count, _bracket_mat, "Brackets")
	var bolt_count := (frame["bolts"] as Array).size()
	if bolt_count > 0:
		var shaft := CylinderMesh.new()
		shaft.top_radius = 1.0
		shaft.bottom_radius = 1.0
		shaft.height = 1.0
		shaft.radial_segments = 10
		_bolt_mm = _make_mm_instance(shaft, bolt_count, _bolt_mat, "Bolts")
		var head := CylinderMesh.new()
		head.top_radius = 1.0
		head.bottom_radius = 1.0
		head.height = 1.0
		head.radial_segments = 6
		_bolt_head_mm = _make_mm_instance(head, bolt_count * 2, _bolt_mat, "BoltHeads")
	if not _last_support.is_empty():
		_support_mm = _make_mm_instance(BoxMesh.new(), _last_support.size(), _wood_mat, "SupportBeams")
	if not _last_panels.is_empty():
		_panel_mm = _make_mm_instance(BoxMesh.new(), _last_panels.size(), _panel_mat, "SolarPanels")
	# Reallocation mints fresh instances carrying the SOLID material, so a
	# ghosted structure would silently turn opaque on the next param change.
	if _ghost_alpha < 0.999:
		set_ghost_alpha(_ghost_alpha)
	# Same trap for build progress: fresh MultiMeshes default to
	# visible_instance_count = -1 (all visible), so a half-built structure
	# would pop fully built on any fold-driven reallocation. The reveal state
	# is cleared FIRST: stale entries under the old MultiMeshes' names made
	# _apply_build_progress skip initializing the fresh ones (the "every panel
	# visible until the target moves" bug), and _process's shown≈target skip
	# then never wrote the count either.
	if not _build_progress.is_empty():
		_reveal_shown.clear()
		_apply_build_progress()


## Unit U-channel: outer 1x1x1 (x=width, y=height, z=depth), open toward +Y.
## Wall/base fractions are baked for a readable silhouette; instance scale
## carries the real bracket dims.
func _build_bracket_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall := 0.16
	# Base plate (closed end at y=0).
	_add_box(st, Vector3(0.0, wall / 2.0, 0.0), Vector3(1.0, wall, 1.0))
	# Side walls along +/-x, full height.
	_add_box(st, Vector3(-0.5 + wall / 2.0, 0.5, 0.0), Vector3(wall, 1.0, 1.0))
	_add_box(st, Vector3(0.5 - wall / 2.0, 0.5, 0.0), Vector3(wall, 1.0, 1.0))
	st.generate_normals()
	return st.commit()


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var h := size / 2.0
	var v := [
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, h.y, -h.z), center + Vector3(-h.x, h.y, -h.z),
		center + Vector3(-h.x, -h.y, h.z), center + Vector3(h.x, -h.y, h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7],
	]
	for f in faces:
		st.add_vertex(v[f[0]])
		st.add_vertex(v[f[2]])
		st.add_vertex(v[f[1]])
		st.add_vertex(v[f[0]])
		st.add_vertex(v[f[3]])
		st.add_vertex(v[f[2]])


# ---------------------------------------------------------------------------
# Transform writes
# ---------------------------------------------------------------------------

func _ground_offset_m() -> float:
	# Lowest corner across all beams -> local Y 0 (inches source).
	if _last_frame.is_empty():
		return 0.0
	return ground_offset_for_frame(_last_frame)


## Metric instance transform for a solver beam dictionary (unit-box mesh).
static func beam_transform(b: Dictionary, ground_offset_m: float) -> Transform3D:
	var length: float = ((b["p2"] as Vector3) - (b["p1"] as Vector3)).length()
	var basis := Basis(
		(b["axis_x"] as Vector3) * float(b["w"]) * INCH_TO_M,
		(b["axis_y"] as Vector3) * float(b["t"]) * INCH_TO_M,
		(b["axis_z"] as Vector3) * length * INCH_TO_M)
	return Transform3D(basis, (b["center"] as Vector3) * INCH_TO_M + Vector3(0, ground_offset_m, 0))


## Metric instance transform for a solver bracket (unit U-channel mesh).
static func bracket_transform(br: Dictionary, ground_offset_m: float) -> Transform3D:
	var bb: Basis = br["basis"]
	var basis := Basis(
		bb.x * float(br["width"]) * INCH_TO_M,
		bb.y * float(br["actual_height"]) * INCH_TO_M,
		bb.z * float(br["depth"]) * INCH_TO_M)
	return Transform3D(basis, (br["bottom_pos"] as Vector3) * INCH_TO_M + Vector3(0, ground_offset_m, 0))


## Metric instance transform for a solver bolt shaft (unit cylinder mesh).
static func bolt_transform(bo: Dictionary, ground_offset_m: float) -> Transform3D:
	var dir: Vector3 = (bo["dir"] as Vector3).normalized()
	var basis := _cylinder_basis(dir, float(bo["radius"]) * INCH_TO_M, float(bo["length"]) * INCH_TO_M)
	return Transform3D(basis, (bo["center"] as Vector3) * INCH_TO_M + Vector3(0, ground_offset_m, 0))


## Metric instance transform for a LinkageGeometry panel (unit-box mesh):
## x = width axis, y = surface normal (thickness), z = length axis.
static func panel_transform(panel: Dictionary, ground_offset_m: float) -> Transform3D:
	var basis := Basis(
		(panel["axis_x"] as Vector3) * float(panel["width"]) * INCH_TO_M,
		(panel["axis_y"] as Vector3) * float(panel["thickness"]) * INCH_TO_M,
		(panel["axis_z"] as Vector3) * float(panel["length"]) * INCH_TO_M)
	return Transform3D(basis, (panel["center"] as Vector3) * INCH_TO_M + Vector3(0, ground_offset_m, 0))


func _write_frame_transforms(frame: Dictionary) -> void:
	var ground := _ground_offset_m()

	var beams: Array = frame["beams"]
	if _beam_mm != null:
		var mm: MultiMesh = _beam_mm.multimesh
		for i in range(beams.size()):
			mm.set_instance_transform(i, beam_transform(beams[i], ground))

	var brackets: Array = frame["brackets"]
	if _bracket_mm != null:
		var mm2: MultiMesh = _bracket_mm.multimesh
		for i in range(brackets.size()):
			mm2.set_instance_transform(i, bracket_transform(brackets[i], ground))

	var bolts: Array = frame["bolts"]
	if _bolt_mm != null:
		var mm3: MultiMesh = _bolt_mm.multimesh
		var mm4: MultiMesh = _bolt_head_mm.multimesh
		var ground_v := Vector3(0.0, ground, 0.0)
		for i in range(bolts.size()):
			var bo: Dictionary = bolts[i]
			var dir: Vector3 = (bo["dir"] as Vector3).normalized()
			mm3.set_instance_transform(i, bolt_transform(bo, ground))
			# Hex head + nut at the two ends.
			var head_r := float(bo["head_radius"]) * INCH_TO_M
			var head_h := float(bo["radius"]) * 1.2 * INCH_TO_M
			var head_basis := _cylinder_basis(dir, head_r, head_h)
			mm4.set_instance_transform(i * 2, Transform3D(head_basis, (bo["start"] as Vector3) * INCH_TO_M + ground_v))
			mm4.set_instance_transform(i * 2 + 1, Transform3D(head_basis, (bo["end"] as Vector3) * INCH_TO_M + ground_v))

	if _support_mm != null:
		var mm5: MultiMesh = _support_mm.multimesh
		for i in range(_last_support.size()):
			mm5.set_instance_transform(i, beam_transform(_last_support[i], ground))

	if _panel_mm != null:
		var mm6: MultiMesh = _panel_mm.multimesh
		for i in range(_last_panels.size()):
			mm6.set_instance_transform(i, panel_transform(_last_panels[i], ground))


# ---------------------------------------------------------------------------
# Collision mesh (hidden MeshInstance3D — feeds PlacedProp collision + pick)
# ---------------------------------------------------------------------------

## Regenerate the hidden per-beam box geometry at the CURRENT fold state.
## NOT called from set_fold_angle (too hot for per-frame animation) — the
## deploy runtime refreshes it once when a fold animation settles.
func refresh_collision_mesh() -> void:
	if _last_frame.is_empty():
		return
	var ground := _ground_offset_m()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var beams: Array = _last_frame["beams"]
	for b in beams + _last_support:
		_add_corner_box(st, b["corners"], ground)
	for panel in _last_panels:
		_add_corner_box(st, _panel_corners(panel), ground)
	var mesh := st.commit()
	var mi := get_node_or_null("CollisionMesh") as MeshInstance3D
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "CollisionMesh"
		mi.visible = false
		add_child(mi)
	mi.mesh = mesh


## Solver corner order (per _make_beam): 4 corners around p1 then 4 around p2,
## both wound -w-t, +w-t, +w+t, -w+t in the beam's cross-section plane.
static func _add_corner_box(st: SurfaceTool, corners: Array, ground_m: float) -> void:
	if corners.size() != 8:
		return
	var v: Array = []
	for c in corners:
		v.append((c as Vector3) * INCH_TO_M + Vector3(0, ground_m, 0))
	# End caps + 4 side quads (two triangles each); winding is irrelevant for
	# ConcavePolygonShape3D and the mesh is never rendered.
	var quads := [
		[0, 1, 2, 3], [4, 7, 6, 5],
		[0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0],
	]
	for q in quads:
		st.add_vertex(v[q[0]])
		st.add_vertex(v[q[1]])
		st.add_vertex(v[q[2]])
		st.add_vertex(v[q[0]])
		st.add_vertex(v[q[2]])
		st.add_vertex(v[q[3]])


## 8 corners (inches) of a LinkageGeometry panel dict, in solver corner order.
static func _panel_corners(panel: Dictionary) -> Array:
	var c: Vector3 = panel["center"]
	var ax: Vector3 = (panel["axis_x"] as Vector3) * (float(panel["width"]) / 2.0)
	var ay: Vector3 = (panel["axis_y"] as Vector3) * (float(panel["thickness"]) / 2.0)
	var az: Vector3 = (panel["axis_z"] as Vector3) * (float(panel["length"]) / 2.0)
	var corners: Array = []
	for ez in [-1.0, 1.0]:
		for o in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			corners.append(c + az * ez + ax * o.x + ay * o.y)
	return corners


## Ground offset (metres) for an arbitrary frame — static for testability.
static func ground_offset_for_frame(frame: Dictionary) -> float:
	var min_y := INF
	for b in frame.get("beams", []):
		for c in b["corners"]:
			min_y = minf(min_y, (c as Vector3).y)
	if min_y == INF:
		return 0.0
	return -min_y * INCH_TO_M


## Basis mapping a unit cylinder (Y axis, height 1, radius 1) onto dir.
static func _cylinder_basis(dir: Vector3, radius: float, length: float) -> Basis:
	var y := dir.normalized()
	if y.length() < 1e-4:
		y = Vector3.UP
	var ref := Vector3(1, 0, 0) if absf(y.y) > 0.99 else Vector3.UP
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x * radius, y * length, z * radius)

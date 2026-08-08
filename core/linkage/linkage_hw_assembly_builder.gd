class_name LinkageHwAssemblyBuilder
extends Node3D
## Renders one hardware assembly as a stack of pickable parts.
##
## Each part from `LinkageHwLayout.compute_axis_layout` becomes a
## MeshInstance3D plus a StaticBody3D + BoxShape3D carrying `part_id` and
## `copy_index` metadata. The collider is what makes Godot-native raycast
## picking possible in the editor modal — three.js has `Raycaster`, Godot has
## the physics server, and a mesh with no body is invisible to it.
##
## Geometry is built in inches by `LinkageHwParts` and scaled once here, so
## every scalar in the layout maths stays comparable with the web app's.

const INCH_TO_M := 0.0254
## Colliders wrap the mesh with a little slack so a thin washer is still
## clickable without having to hit it pixel-perfectly.
const PICK_PAD_M := 0.004

var _assembly: Dictionary = {}
var _explode := 0.0
var _exclude_beams := false
var _selected := ""
var _selected_copy := 0
var _nodes: Dictionary = {}          # "id|copy" -> MeshInstance3D (source axis only)
var _mesh_cache: Dictionary = {}     # "type|params|mirrored" -> ArrayMesh
## Everything actually drawn, mirrors included, with the layout item that
## produced it. Explode then rewrites transforms straight from this — no
## re-walking the axes, and no mirrored part left stranded behind.
var _placed: Array = []              # [{node, item, render_axis, origin}]
var _instances: Array = []           # dimmed context clones at the other joints
var _stack_root: Node3D = null


func _ready() -> void:
	if _stack_root == null:
		_stack_root = Node3D.new()
		_stack_root.name = "Stack"
		add_child(_stack_root)


## Build (or rebuild) the whole stack.
##
## `exclude_beams` drops the preview timber while KEEPING its slot in the
## layout, so everything threaded onto the stack still sits where it should.
## The in-structure view uses it because the real frame already draws those
## members — without it every joint stamps another translucent eight-foot beam
## over the one that is genuinely there (`shouldRenderPart`,
## hardware-detail.js:476).
func set_assembly(asm: Dictionary, explode: float = 0.0,
		exclude_beams: bool = false) -> void:
	_assembly = asm
	_explode = clampf(explode, 0.0, 1.0)
	_exclude_beams = exclude_beams
	_rebuild()


## Repeat the built stack at every other joint that uses this assembly.
##
## `transforms` are in the solver's INCH space (LinkageHwPlacement). The FIRST
## one is skipped — that joint is the editable stack itself, sitting at this
## node's own origin; the rest are context copies, cloned rather than rebuilt
## so eight modules cost eight duplicates instead of eight full mesh passes.
## Clones share their meshes, and are excluded from picking so a click always
## lands on the part you are actually editing.
func set_instances(transforms: Array, ground_offset_m: float = 0.0) -> void:
	for node in _instances:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_instances.clear()
	if transforms.size() <= 1 or _stack_root == null:
		return
	# Clones are children of THIS node, which is already seated on transforms[0].
	# Their `transform` is therefore a LOCAL one and must have that seat divided
	# out — assigning the absolute seat directly composes the two, putting joint
	# i at seat0 * seat_i. That reads as "the focused joint is right and every
	# other one is scattered", because the first joint IS this node and is the
	# only one the double transform misses.
	var inv := transform.affine_inverse()
	for i in range(1, transforms.size()):
		var clone := _stack_root.duplicate() as Node3D
		if clone == null:
			continue
		clone.name = "Context%d" % i
		clone.transform = inv * seat_transform(transforms[i] as Transform3D,
			ground_offset_m)
		for body in _find_bodies(clone):
			body.get_parent().remove_child(body)
			body.queue_free()
		# Context copies are never "selected" — but duplicate() carries the
		# highlight material across, so whichever part happened to be selected
		# when the clones were minted lit up at every joint on the frame.
		for mi in _find_meshes(clone):
			mi.material_override = null
		add_child(clone)
		_instances.append(clone)


func instance_count() -> int:
	return _instances.size()


## A solver-space placement (rotation + INCH position) as a node transform.
##
## Only the POSITION converts to metres: the parts already bake the inch scale
## into their own transforms, so scaling the seat as well would shrink the
## whole joint by another factor of 0.0254.
##
## `ground_offset_m` must match whatever the structure alongside it used —
## `LinkageStructureBuilder` lifts its frame so the lowest beam corner rests on
## Y=0, and a placement that skips that lift floats off the structure entirely.
static func seat_transform(placement: Transform3D,
		ground_offset_m: float = 0.0) -> Transform3D:
	return Transform3D(placement.basis.orthonormalized(),
		placement.origin * INCH_TO_M + Vector3(0.0, ground_offset_m, 0.0))


static func _find_meshes(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		out.append_array(_find_meshes(child))
	return out


static func _find_bodies(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is StaticBody3D:
			out.append(child)
		else:
			out.append_array(_find_bodies(child))
	return out


## Drop this builder's OWN pick bodies — for context builders showing other
## assemblies, whose parts must never answer a raycast meant for the editable
## stack.
func strip_pick_bodies() -> void:
	if _stack_root == null:
		return
	for body in _find_bodies(_stack_root):
		body.get_parent().remove_child(body)
		body.queue_free()


func assembly() -> Dictionary:
	return _assembly


## Explode without rebuilding — transforms only, so the slider stays smooth.
func set_explode(explode: float) -> void:
	var want := clampf(explode, 0.0, 1.0)
	if is_equal_approx(want, _explode):
		return
	_explode = want
	_reposition()
	sync_instances()


func get_explode() -> float:
	return _explode


## Move ONE part without rebuilding anything.
##
## This is cheap because of a property of `compute_axis_layout`: the cursor it
## walks along an axis advances by `qty_assembled_span + CHAIN_CLEARANCE` and
## ignores `posAssembled` entirely, so a part's offset moves that part (and its
## mirror, which shares the id) and nothing else. Patching `base_start` in place
## and re-issuing `part_transform` is therefore exactly equivalent to a full
## re-layout, at no allocation.
func set_part_offset(part_id: String, pos_assembled: float) -> void:
	if _assembly.is_empty() or part_id == "":
		return
	var touched := false
	for entry in _placed:
		var e := entry as Dictionary
		var it := e["item"] as Dictionary
		if str((it["part"] as Dictionary).get("id", "")) != part_id:
			continue
		it["base_start"] = float(it["part_base"]) + pos_assembled \
			+ float(it["len"]) * int(it["copy_index"])
		var node := e["node"] as Node3D
		if is_instance_valid(node):
			node.transform = part_transform(it, _assembly, _explode,
				str(e["render_axis"]), float(e["origin"]))
			touched = true
	if touched:
		sync_instances()


## Re-place the anchoring bracket after its local nudge changed. It is not in
## `_placed` (it has no layout item — it is what the layouts hang off), so
## `refresh_part` cannot reach it.
func refresh_bracket() -> void:
	if _assembly.is_empty():
		return
	var bracket := LinkageHardware.bracket_part(_assembly)
	if bracket.is_empty():
		return
	var node := _nodes.get(_key(str(bracket.get("id", "")), 0)) as Node3D
	if node == null:
		return
	node.transform = _bracket_transform(bracket)
	sync_instances()


## Re-place one part after a non-layout field (crossOffset, flipAxis) changed.
## Same cheap path — `part_transform` re-reads the part dict every call.
func refresh_part(part_id: String) -> void:
	if _assembly.is_empty() or part_id == "":
		return
	var touched := false
	for entry in _placed:
		var e := entry as Dictionary
		if str(((e["item"] as Dictionary)["part"] as Dictionary).get("id", "")) != part_id:
			continue
		var node := e["node"] as Node3D
		if is_instance_valid(node):
			node.transform = part_transform(e["item"] as Dictionary, _assembly,
				_explode, str(e["render_axis"]), float(e["origin"]))
			touched = true
	if touched:
		sync_instances()


## Push the editable stack's pose onto the context clones at the other joints.
##
## `set_instances` DUPLICATES `_stack_root`, so a clone is frozen at whatever
## pose it was copied at: exploding the stack used to fan out the joint under
## the camera while every other joint on the frame stayed shut. Re-cloning per
## slider tick would cost more than the bug, so the poses are mapped by child
## index — `duplicate()` preserves child order, and the pick bodies that were
## stripped from clones are GRANDchildren, so the mapping is exact.
func sync_instances() -> void:
	if _stack_root == null or _instances.is_empty():
		return
	var n := _stack_root.get_child_count()
	for clone in _instances:
		var c := clone as Node3D
		if not is_instance_valid(c):
			continue
		for i in mini(c.get_child_count(), n):
			var dst := c.get_child(i) as Node3D
			var src := _stack_root.get_child(i) as Node3D
			if dst != null and src != null:
				dst.transform = src.transform


func part_node(part_id: String, copy_index: int = 0) -> Node3D:
	return _nodes.get(_key(part_id, copy_index))


## Extent of the HARDWARE alone, in metres, local to this node.
##
## Beams are excluded on purpose: a synced V-beam is eight feet long while the
## joint it passes through is a few inches, so framing on everything would put
## the camera far enough away to make the subject a speck. The beams are
## context — they are allowed to run off-screen.
func hardware_aabb() -> AABB:
	var out := AABB()
	var seeded := false
	for key in _nodes:
		var mi := _nodes[key] as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if str(mi.get_meta("part_type", "")) == "beam":
			continue
		var box := mi.transform * mi.mesh.get_aabb()
		if not seeded:
			out = box
			seeded = true
		else:
			out = out.merge(box)
	return out


func selected_part_id() -> String:
	return _selected


## Highlight one part (or clear with ""). Cosmetic only.
func set_selected(part_id: String, copy_index: int = 0) -> void:
	_selected = part_id
	_selected_copy = copy_index
	var want := _key(part_id, copy_index)
	for key in _nodes:
		var mi := _nodes[key] as MeshInstance3D
		if mi == null:
			continue
		# A tint rather than an outline: the parts are small and an outline at
		# this scale swallows the part it is meant to point at.
		mi.material_override = _selection_material() if str(key) == want else null


static var _sel_mat: StandardMaterial3D = null

static func _selection_material() -> StandardMaterial3D:
	if _sel_mat == null:
		_sel_mat = StandardMaterial3D.new()
		_sel_mat.albedo_color = UITheme.C_PRIMARY
		_sel_mat.emission_enabled = true
		_sel_mat.emission = UITheme.C_PRIMARY
		_sel_mat.emission_energy_multiplier = 0.35
		_sel_mat.metallic = 0.5
		_sel_mat.roughness = 0.35
	return _sel_mat


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _rebuild() -> void:
	if _stack_root == null:
		_stack_root = Node3D.new()
		_stack_root.name = "Stack"
		add_child(_stack_root)
	# Detach BEFORE queueing the free. queue_free is deferred to end-of-frame,
	# so a second rebuild in the same frame — two edits in one drag, say —
	# would otherwise see the previous stack still parented: doubled geometry,
	# and stale pick bodies still answering raycasts.
	for child in _stack_root.get_children():
		_stack_root.remove_child(child)
		child.queue_free()
	_nodes.clear()
	_placed.clear()
	if _assembly.is_empty():
		return

	# The bracket anchors the joint rather than sitting in a stack, so it is
	# placed on its own before the axes are walked.
	var bracket := LinkageHardware.bracket_part(_assembly)
	if not bracket.is_empty():
		_spawn(bracket, 0, _bracket_transform(bracket))

	for axis_key in LinkageHwLayout.AXES:
		_build_axis(axis_key, str(axis_key))
	# Mirrored axes render the SOURCE parts on the far side, so editing either
	# side writes one part (LinkageHwLayout.mirror_part keeps the source id).
	# An axis that already holds real parts is NOT mirrored onto — those are
	# physical clones and drawing the source there too would double them up.
	for pair in LinkageHardware.mirror_pairs(_assembly):
		var from_axis := str((pair as Dictionary)["from"])
		var to_axis := str((pair as Dictionary)["to"])
		if not LinkageHardware.parts_on_axis(_assembly, to_axis).is_empty():
			continue
		_build_axis(from_axis, to_axis)
	if _selected != "":
		set_selected(_selected, _selected_copy)


func _build_axis(parts_axis: String, render_as: String) -> void:
	var layout := LinkageHwLayout.compute_axis_layout(_assembly, parts_axis)
	var items: Array = layout["items"]
	if items.is_empty():
		return
	var mirrored := parts_axis != render_as
	var origin := float(layout["origin"])
	for item in items:
		var it := item as Dictionary
		var part := it["part"] as Dictionary
		var copy_index := int(it["copy_index"])
		# Skipped parts keep their slot above; they simply are not drawn.
		if _exclude_beams and str(part.get("type", "")) == "beam":
			continue
		var xf := part_transform(it, _assembly, _explode, render_as, origin)
		var node := _spawn(part, copy_index, xf, mirrored, render_as)
		if node == null:
			continue
		if mirrored:
			node.name = "%s_%s_%d" % [str(part["id"]), render_as, copy_index]
		_placed.append({"node": node, "item": it, "render_axis": render_as,
			"origin": origin})


## World transform of one laid-out item.
##
## `render_axis` is normally the part's own axis; for a mirrored copy it is the
## far side, which is what makes a stored "right" stack draw on the left too.
## `layout_origin` is the axis layout's origin, needed for the exploded pose.
static func part_transform(item: Dictionary, asm: Dictionary, explode: float,
		render_axis: String = "", layout_origin: float = 0.0) -> Transform3D:
	var part := item["part"] as Dictionary
	var axis_key := str(part.get("axis", "right"))
	var render := render_axis
	if render == "" or render == "center":
		render = LinkageHwLayout.center_render_axis(asm) if render == "center" \
			or LinkageHwLayout.is_center_axis(axis_key) else axis_key
	if LinkageHwLayout.is_center_axis(render):
		render = LinkageHwLayout.center_render_axis(asm)
	var dir: Vector3 = LinkageHwLayout.AXIS_DIRS.get(render, Vector3.RIGHT)
	var cross: Vector3 = LinkageHwLayout.AXIS_CROSS.get(render, Vector3.UP)

	# Blend the assembled and exploded starts, then walk out along the axis.
	var copy_index := int(item["copy_index"])
	var assembled := float(item["base_start"])
	var exploded := LinkageHwLayout.exploded_axis_pos(part, layout_origin,
		int(item["rank"]), float(asm.get("explodeGap", 1.4))) \
		+ LinkageHwLayout.qty_explode_gap(part) * copy_index
	var start: float = lerpf(assembled, exploded, clampf(explode, 0.0, 1.0))

	# A HORIZONTAL chain hangs off the bracket's side wall, and that wall's bolt
	# hole is `bracket_hole_y` above the bracket's centre — which is the
	# assembly origin. Without this lift the whole V-beam stack floats at the
	# bracket's mid-height instead of threading through its hole, and nothing
	# lines up (hwLayoutAxisParts :477).
	var cross_in := float(part.get("crossOffset", 0.0))
	if LinkageHwLayout.HORIZONTAL_AXES.has(render):
		var bracket := LinkageHardware.bracket_part(asm)
		if not bracket.is_empty():
			cross_in += LinkageHwLayout.bracket_hole_y(bracket)

	# Anchor on the part's axial CENTRE, exactly as the web does
	# (`hwCenterMeshAxially` + `hwPartAxisPlacementPos` = start + len/2).
	# Anchoring on the start looked identical for straight parts but shifted
	# every `flipAxis` part a full part-length out of its slot: the flip is a
	# half-turn, and a half-turn about the START relocates the body while one
	# about the CENTRE only reverses it — which is what flipping a bolt
	# end-for-end physically means.
	var plen := float(item["len"])
	var axis_pos := start + plen / 2.0
	# Parts are modelled along +Y; rotate that onto the render axis, then flip
	# end-for-end when asked. The flip is a half turn about the part's own X,
	# matching the web app's `flipEnd` quaternion — NOT simply aiming at -dir,
	# which would also roll the part and spin a beam's length off true.
	var basis := _basis_for(dir)
	if bool(part.get("flipAxis", false)):
		basis = basis * Basis(Vector3.RIGHT, PI)
	var basis_scaled := basis.scaled(Vector3.ONE * INCH_TO_M)
	# Meshes span [0, len] locally, so step back half a length through the
	# (possibly flipped) basis to centre them on the anchor.
	var origin := dir * (axis_pos * INCH_TO_M) + cross * (cross_in * INCH_TO_M) \
		+ basis_scaled * Vector3(0.0, -plen / 2.0, 0.0)
	return Transform3D(basis_scaled, origin)


## Rotation taking model +Y onto `dir`.
static func _basis_for(dir: Vector3) -> Basis:
	if dir.is_equal_approx(Vector3.UP):
		return Basis.IDENTITY
	if dir.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, PI)
	var axis := Vector3.UP.cross(dir)
	if axis.length() < 1e-6:
		return Basis.IDENTITY
	return Basis(axis.normalized(), Vector3.UP.angle_to(dir))


## The bracket sits centred on the assembly origin, its own height straddling
## it, because the pivot is measured from the bracket's CENTRE.
func _bracket_transform(bracket: Dictionary) -> Transform3D:
	var h := LinkageHwLayout.part_axial_length(bracket)
	var pr: Dictionary = bracket.get("params", {})
	var offset := Vector3(
		float(pr.get("posX", 0.0)), -h / 2.0 + float(pr.get("posY", 0.0)),
		float(pr.get("posZ", 0.0))) * INCH_TO_M
	return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * INCH_TO_M), offset)


func _spawn(part: Dictionary, copy_index: int, xf: Transform3D,
		mirrored: bool = false, render_axis: String = "") -> MeshInstance3D:
	var mesh := _mesh_for(part, mirrored)
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "%s_%d" % [str(part.get("id", "part")), copy_index]
	mi.set_meta("part_type", str(part.get("type", "")))
	mi.material_override = null
	mi.set_surface_override_material(0,
		LinkageHwParts.material_for(str(part.get("type", ""))))
	mi.transform = xf
	_stack_root.add_child(mi)

	# Pick body. Mirrored copies get one too — clicking either side selects
	# the same underlying part.
	var body := StaticBody3D.new()
	body.name = "Pick"
	body.set_meta("part_id", str(part.get("id", "")))
	body.set_meta("copy_index", copy_index)
	body.set_meta("mirrored", mirrored)
	# The axis this BODY was drawn along, which for a mirror is the far side.
	# A dragger that measures along the part's stored axis instead sends the
	# left-hand copy of a `right` stack backwards under the cursor.
	body.set_meta("render_axis", render_axis)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var aabb := mesh.get_aabb()
	box.size = aabb.size * xf.basis.get_scale() + Vector3.ONE * PICK_PAD_M
	shape.shape = box
	shape.position = aabb.get_center() * xf.basis.get_scale()
	body.add_child(shape)
	mi.add_child(body)

	if not mirrored:
		_nodes[_key(str(part.get("id", "")), copy_index)] = mi
	return mi


## Mesh for a part, memoized on its type and parameters.
##
## Editing a stack rebuilds it, and a drilled beam is by far the priciest mesh
## here — three bores tiled band by band. Almost every rebuild changes ONE
## part, so caching on content means the other ten are handed back untouched.
## The cache is per-builder and dies with the modal, which is the right
## lifetime: the parameters it keys on are the ones the player is editing.
func _mesh_for(part: Dictionary, mirrored: bool) -> ArrayMesh:
	var spec := part
	# A mirrored beam is reflected about the stack, so its member has to lean
	# the other way: rotDeg -> 180 - rotDeg (`hwCreatePartMeshForAxis` :1542).
	# Nothing else cares which side it is drawn on.
	if mirrored and str(part.get("type", "")) == "beam":
		spec = part.duplicate(true)
		var pr: Dictionary = spec.get("params", {})
		pr["rotDeg"] = 180.0 - float(pr.get("rotDeg", 90.0))
		spec["params"] = pr
	var key := "%s|%s|%s" % [str(spec.get("type", "")),
		JSON.stringify(spec.get("params", {})), str(mirrored)]
	var hit = _mesh_cache.get(key)
	if hit is ArrayMesh:
		return hit
	var mesh := LinkageHwParts.mesh_for(spec)
	if mesh != null:
		_mesh_cache[key] = mesh
	return mesh


## Explode changed: rewrite transforms from the placement record.
##
## No mesh rebuild and no axis re-walk — the slider fires many times a second,
## and re-deriving five layouts per frame to move eleven nodes was the whole
## cost. Driving it off `_placed` also means MIRRORED parts move too; keying
## the old version on `_nodes` left them behind while the rest flew apart.
func _reposition() -> void:
	if _assembly.is_empty():
		return
	for entry in _placed:
		var e := entry as Dictionary
		var node := e["node"] as Node3D
		if not is_instance_valid(node):
			continue
		node.transform = part_transform(e["item"] as Dictionary, _assembly,
			_explode, str(e["render_axis"]), float(e["origin"]))


func _key(part_id: String, copy_index: int) -> String:
	return "%s|%d" % [part_id, copy_index]

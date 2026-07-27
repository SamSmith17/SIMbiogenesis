class_name PipePartsAssembler
extends RefCounted

## Assemble a pipe-kit BOM: procedural tubes for straights, MultiMesh for elbows.


static func ensure_host(parent: Node, cid: String) -> Node3D:
	var name := "PipeParts_%s" % cid
	var existing := parent.get_node_or_null(name) as Node3D
	if existing != null:
		return existing
	var host := Node3D.new()
	host.name = name
	parent.add_child(host)
	return host


static func clear(parent: Node, cid: String) -> void:
	var host := parent.get_node_or_null("PipeParts_%s" % cid)
	if host != null:
		parent.remove_child(host)
		host.free()


## Apply BOM. Returns {centerline, elbows: Array[{bend_deg, transform, corner_i, mm_name, instance_i}]}.
static func apply(parent: Node, cid: String, bom: Dictionary, kit: PipeKit,
		material: Material) -> Dictionary:
	clear(parent, cid)
	var result := {
		"centerline": PackedVector3Array(),
		"elbows": [],
	}
	if not bool(bom.get("ok", false)) or kit == null:
		return result
	var parts: Array = bom.get("parts", []) as Array
	if parts.is_empty():
		return result
	var host := ensure_host(parent, cid)
	var elbow_groups := {"45": [], "90": []}  ## Array of {transform, corner_i, bend_deg}
	var straight_i := 0
	var radius := kit.nominal_od_m * 0.5
	for p: Variant in parts:
		var d: Dictionary = p
		var kind := str(d.get("kind", ""))
		if kind == "straight" or kind == "straight_rem":
			var from: Vector3 = d.get("from", Vector3.ZERO) as Vector3
			var to: Vector3 = d.get("to", Vector3.ZERO) as Vector3
			if from.distance_to(to) < 1e-6:
				continue
			var path := PackedVector3Array([from, to])
			var mesh := ConduitMeshBuilder.build_tube(path, radius, 10)
			var mi := MeshInstance3D.new()
			mi.name = "Straight_%d" % straight_i
			straight_i += 1
			mi.mesh = mesh
			mi.material_override = material
			# Shadows ground the dull plastic; OFF made PVC look self-lit at night.
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			host.add_child(mi)
			continue
		if kind == "elbow":
			var bd := int(round(float(d.get("bend_deg", 90.0))))
			var key := str(bd) if bd > 0 else "90"
			if not elbow_groups.has(key):
				elbow_groups[key] = []
			(elbow_groups[key] as Array).append({
				"transform": d.get("transform", Transform3D()) as Transform3D,
				"corner_i": int(d.get("corner_i", -1)),
				"bend_deg": float(d.get("bend_deg", bd)),
				"corner": d.get("corner", Vector3.ZERO) as Vector3,
			})
	var elbows: Array = []
	for key: String in elbow_groups.keys():
		var entries: Array = elbow_groups[key] as Array
		if entries.is_empty():
			continue
		var part: Dictionary = kit.parts.get(key, {}) as Dictionary
		var mesh: Mesh = part.get("mesh", null) as Mesh
		if mesh == null:
			continue
		var xforms: Array = []
		for e: Variant in entries:
			var xf: Transform3D = (e as Dictionary).get("transform", Transform3D()) as Transform3D
			if not _xform_finite(xf):
				continue
			xforms.append(xf)
		if xforms.is_empty():
			continue
		var mm_name := "MM_%s" % key
		_make_mm(host, mm_name, mesh, xforms, material)
		for i: int in range(entries.size()):
			var e: Dictionary = entries[i]
			elbows.append({
				"bend_deg": float(e.get("bend_deg", 0.0)),
				"transform": e.get("transform", Transform3D()) as Transform3D,
				"corner_i": int(e.get("corner_i", -1)),
				"corner": e.get("corner", Vector3.ZERO) as Vector3,
				"mm_name": mm_name,
				"instance_i": i,
			})
	result["elbows"] = elbows
	var cl: PackedVector3Array = bom.get("centerline", PackedVector3Array()) as PackedVector3Array
	if cl.size() >= 2:
		result["centerline"] = cl
	else:
		result["centerline"] = _centerline_from_parts(parts)
	return result


## Legacy helper: centerline only (tests / callers that ignore elbow cache).
static func apply_centerline(parent: Node, cid: String, bom: Dictionary, kit: PipeKit,
		material: Material) -> PackedVector3Array:
	return apply(parent, cid, bom, kit, material).get("centerline", PackedVector3Array()) \
			as PackedVector3Array


static func _make_mm(host: Node3D, mm_name: String, mesh: Mesh, xforms: Array,
		material: Material) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i: int in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i] as Transform3D)
	var inst := MultiMeshInstance3D.new()
	inst.name = mm_name
	inst.multimesh = mm
	inst.material_override = material
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	host.add_child(inst)


static func _xform_finite(xf: Transform3D) -> bool:
	var o := xf.origin
	if not is_finite(o.x) or not is_finite(o.y) or not is_finite(o.z):
		return false
	for i: int in range(3):
		var ax: Vector3 = xf.basis[i]
		if not is_finite(ax.x) or not is_finite(ax.y) or not is_finite(ax.z):
			return false
		if ax.length_squared() < 1e-12:
			return false
	return true


static func _centerline_from_parts(parts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Variant in parts:
		var d: Dictionary = p
		var kind := str(d.get("kind", ""))
		if kind == "straight" or kind == "straight_rem":
			var from: Vector3 = d.get("from", Vector3.ZERO) as Vector3
			var to: Vector3 = d.get("to", Vector3.ZERO) as Vector3
			if out.is_empty():
				out.append(from)
			out.append(to)
			continue
		var xf: Transform3D = d.get("transform", Transform3D()) as Transform3D
		out.append(xf.origin)
	return out

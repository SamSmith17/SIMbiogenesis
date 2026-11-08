class_name IntermodalUnitBuilder
extends RefCounted
## Procedural placed model for any IntermodalUnits entry (ModelCatalog id
## `intermodal_unit`, record key `intermodal_spec` = {template, params,
## label, unit_id}). One MeshInstance3D "Mesh", origin at the ground centre,
## length along Z with a container's door at +Z.

const MODEL_ID := "intermodal_unit"
const RACK_STEEL := Color(0.18, 0.32, 0.62)
const RACK_BEAM := Color(0.92, 0.48, 0.12)


static func entry_for_spec(spec: Dictionary) -> Dictionary:
	var uid := str(spec.get("unit_id", ""))
	if uid != "":
		var found: Dictionary = IntermodalUnits.find(uid)
		if not found.is_empty():
			return found
	var tid := str(spec.get("template", "pallet_eur1"))
	if IntermodalUnits.template(tid).is_empty():
		tid = "pallet_eur1"
	var params: Dictionary = spec.get("params", {})
	return IntermodalUnits.resolve(tid, params, uid, str(spec.get("label", "")))


static func build_node(spec: Dictionary = {}, node_name: String = "IntermodalUnit") -> Node3D:
	var entry := entry_for_spec(spec)
	var root: Node3D
	var fam := str(entry.get("family", ""))
	if fam == "container":
		root = CargoContainerBuilder.build_from_entry(entry, node_name,
			{"doors_open_deg": float(spec.get("doors_open_deg", 0.0))})
	elif fam == "ibc":
		# The real tote (assets/packing/ibc_tote.glb), procedural when absent.
		root = IbcBuilder.build(entry, node_name)
	else:
		root = Node3D.new()
		root.name = node_name
		var mesh := ArrayMesh.new()
		match str(entry.get("family", "")):
			"pallet":
				PalletBuilder.emit(mesh, entry)
			"ibc":
				IbcBuilder.emit(mesh, entry)   # unreachable: handled above
			"gaylord":
				GaylordBuilder.emit(mesh, entry)
			"drum":
				DrumBuilder.emit(mesh, entry)
			"rack_bay":
				_emit_rack(mesh, entry)
			_:
				PalletBuilder.emit(mesh, entry)
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = mesh
		root.add_child(mi)
	root.set_meta("intermodal_spec", {
		"template": str(entry.get("template", "")),
		"params": (entry.get("params", {}) as Dictionary).duplicate(true),
		"label": str(entry.get("label", "")),
		"unit_id": str(spec.get("unit_id", "")),
	})
	return root


## Two upright frames at ±X (each two posts + bracing), a beam pair per level.
static func _emit_rack(mesh: ArrayMesh, entry: Dictionary) -> void:
	var p: Dictionary = entry.get("params", {})
	var bl := float(p.get("beam_l_m", 2.7))
	var fd := float(p.get("frame_d_m", 1.1))
	var fh := float(p.get("frame_h_m", 4.0))
	var levels := maxi(int(p.get("levels", 3)), 1)
	var post := 0.08
	var frames := IntermodalMeshKit.new()
	for sx in [-1.0, 1.0]:
		var x: float = sx * (bl * 0.5 + post * 0.5)
		for sz in [-1.0, 1.0]:
			frames.box(Vector3(x, fh * 0.5, sz * (fd - post) * 0.5), Vector3(post, fh, post))
		var n := maxi(int(fh / 0.9), 2)
		for i in n:
			var y0 := fh * float(i) / float(n) + 0.15
			var y1 := fh * float(i + 1) / float(n)
			var z0: float = -(fd - post) * 0.5 if i % 2 == 0 else (fd - post) * 0.5
			var a := Vector3(x, y0, z0)
			var b := Vector3(x, y1, -z0)
			var mid := (a + b) * 0.5
			var ay := b - a
			var len := ay.length()
			if len < 0.01:
				continue
			ay = ay.normalized()
			var ax := Vector3(1, 0, 0)
			var az := ax.cross(ay).normalized()
			frames.obox(mid, ax * 0.02, ay * (len * 0.5), az * 0.02)
		frames.box(Vector3(x, 0.01, 0.0), Vector3(0.14, 0.02, fd))
	frames.commit(mesh, RACK_STEEL, 0.4, 0.55)
	var beams := IntermodalMeshKit.new()
	for i in levels:
		var y := fh * float(i + 1) / float(levels + 1)
		for sz in [-1.0, 1.0]:
			beams.box(Vector3(0.0, y, sz * (fd - post) * 0.5), Vector3(bl, 0.11, 0.05))
	beams.commit(mesh, RACK_BEAM, 0.3, 0.5)

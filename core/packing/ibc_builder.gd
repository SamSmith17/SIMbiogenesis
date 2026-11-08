class_name IbcBuilder
extends RefCounted
## An IBC tote. The REAL model is the one in the project's own site export
## (the IBC_DXF assembly of the Mars site GLB), pulled out once by
## tools/diag/ibc_extract.gd into assets/packing/ibc_tote.glb at the nominal
## 1000 L size (pallet 1.2 x 1.0 m, 1.16 m tall, length along Z, the valve
## at +Z, floor at y = 0). `build` instantiates that, scales it per axis to
## the entry's outside dims and gives it honest materials (translucent HDPE
## bottle, galvanised cage, a dark pallet, black valve). Where the GLB is
## missing (a bare clone before the import, a selftest) the procedural
## tote below stands in, so the packing data never depends on art.

const GLB_PATH := "res://assets/packing/ibc_tote.glb"
## The box the GLB was baked to (ibc_extract.gd).
const BAKED_L := 1.2
const BAKED_W := 1.0
const BAKED_H := 1.16

const BOTTLE := Color(0.92, 0.93, 0.90)
const CAGE := Color(0.70, 0.72, 0.74)
const BASE := Color(0.28, 0.30, 0.32)
const VALVE := Color(0.15, 0.15, 0.16)

static var _scene: PackedScene = null
static var _scene_checked := false
static var _mats: Dictionary = {}


## True when the real model is available.
static func has_model() -> bool:
	_load_scene()
	return _scene != null


## The tote as a node: the GLB when present, else the procedural mesh
## under one "Mesh" child. Either way the root's children are
## MeshInstance3Ds (PlacedProp.setup_collision walks them).
static func build(entry: Dictionary, node_name: String = "IbcTote") -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var ex: Dictionary = entry.get("exterior", {})
	var l := float(ex.get("l_m", BAKED_L))
	var w := float(ex.get("w_m", BAKED_W))
	var h := float(ex.get("h_m", BAKED_H))
	_load_scene()
	if _scene != null:
		var inst := _scene.instantiate() as Node3D
		if inst != null:
			inst.name = "Model"
			inst.scale = Vector3(w / BAKED_W, h / BAKED_H, l / BAKED_L)
			_dress(inst)
			root.add_child(inst)
			root.set_meta("ibc_model", true)
			return root
	var mesh := ArrayMesh.new()
	emit(mesh, entry)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	return root


static func _load_scene() -> void:
	if _scene_checked:
		return
	_scene_checked = true
	if ResourceLoader.exists(GLB_PATH):
		var res: Resource = load(GLB_PATH)
		if res is PackedScene:
			_scene = res


static func _mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material
	match key:
		"bottle":
			var b := StructureMaterials.make(StructureMaterials.Kind.PLASTIC, BOTTLE)
			b.albedo_color = Color(BOTTLE.r, BOTTLE.g, BOTTLE.b, 0.82)
			b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			b.roughness = 0.45
			m = b
		"cage":
			m = StructureMaterials.make(StructureMaterials.Kind.GALVANISED, CAGE)
		"base":
			m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, BASE)
		_:
			m = StructureMaterials.make(StructureMaterials.Kind.PLASTIC, VALVE)
	_mats[key] = m
	return m


## Honest looks by part: the SketchUp export carries flat SimLab colours.
## The bottle is the largest mesh, the cage every tube, the pallet whatever
## stands under 0.17 m, the rest (valve, cap, corner blocks) black.
static func _dress(inst: Node3D) -> void:
	var meshes := inst.find_children("*", "MeshInstance3D", true, false)
	var biggest: MeshInstance3D = null
	var big_vol := 0.0
	for m in meshes:
		var mi := m as MeshInstance3D
		var a := mi.get_aabb()
		var vol := a.size.x * a.size.y * a.size.z
		if vol > big_vol:
			big_vol = vol
			biggest = mi
	for m in meshes:
		var mi := m as MeshInstance3D
		var n := mi.name.to_lower()
		var pn := mi.get_parent().name.to_lower() if mi.get_parent() != null else ""
		var key := "valve"
		if mi == biggest:
			key = "bottle"
		elif n.contains("cylinder") or n.contains("cage") or pn.contains("cylinder") or pn.contains("cage"):
			key = "cage"
		else:
			# Local AABB in the model's own (metre) frame.
			var top := (mi.transform * mi.get_aabb()).end.y
			var p := mi.get_parent() as Node3D
			if p != null:
				top = (p.transform * mi.transform * mi.get_aabb()).end.y
			if top < 0.17:
				key = "base"
		mi.material_override = _mat(key)


## The procedural tote: a steel pallet base, a translucent white HDPE bottle
## and the galvanised cage round it, a fill cap on top and a valve at the
## front (+Z). Length along Z, floor at y = 0.
static func emit(mesh: ArrayMesh, entry: Dictionary) -> void:
	var ex: Dictionary = entry.get("exterior", {})
	var l := float(ex.get("l_m", 1.2))
	var w := float(ex.get("w_m", 1.0))
	var h := float(ex.get("h_m", 1.16))
	var p: Dictionary = entry.get("params", {})
	var deck := float(p.get("deck_h_m", 0.15))
	var base := IntermodalMeshKit.new()
	var bottle := IntermodalMeshKit.new()
	var cage := IntermodalMeshKit.new()
	var valve := IntermodalMeshKit.new()
	# Base: a deck plate on four corner feet and a centre runner.
	base.box(Vector3(0, deck - 0.02, 0), Vector3(w, 0.04, l))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			base.box(Vector3(sx * (w * 0.5 - 0.06), (deck - 0.04) * 0.5,
				sz * (l * 0.5 - 0.06)), Vector3(0.12, deck - 0.04, 0.12))
	base.box(Vector3(0, (deck - 0.04) * 0.5, 0), Vector3(0.12, deck - 0.04, l * 0.6))
	# Bottle, inset a little inside the cage.
	var bh := h - deck - 0.04
	bottle.box(Vector3(0, deck + bh * 0.5, 0), Vector3(w - 0.06, bh, l - 0.06))
	bottle.cylinder(Vector3(0, h - 0.01, 0), 0.075, 0.04)
	# Cage: tubes on all four sides.
	var tube := 0.022
	var ct := h - deck
	for sx in [-1.0, 1.0]:
		var n_v := maxi(3, int(round(l / 0.2)))
		for i in n_v + 1:
			var z := -l * 0.5 + l * float(i) / float(n_v)
			cage.box(Vector3(sx * w * 0.5, deck + ct * 0.5, z), Vector3(tube, ct, tube))
	for sz in [-1.0, 1.0]:
		var n_v2 := maxi(3, int(round(w / 0.2)))
		for i in n_v2 + 1:
			var x := -w * 0.5 + w * float(i) / float(n_v2)
			cage.box(Vector3(x, deck + ct * 0.5, sz * l * 0.5), Vector3(tube, ct, tube))
	var rings := maxi(3, int(round(ct / 0.2)))
	for i in rings + 1:
		var y := deck + ct * float(i) / float(rings)
		for sx in [-1.0, 1.0]:
			cage.box(Vector3(sx * w * 0.5, y, 0), Vector3(tube, tube, l))
		for sz in [-1.0, 1.0]:
			cage.box(Vector3(0, y, sz * l * 0.5), Vector3(w, tube, tube))
	# Valve at the front, near the bottom.
	valve.cylinder(Vector3(0, deck + 0.09, l * 0.5 + 0.05), 0.05, 0.10,
		Vector3.BACK, 14)
	base.commit(mesh, BASE, 0.4, 0.6)
	bottle.commit(mesh, BOTTLE, 0.0, 0.45, 0.85)
	cage.commit(mesh, CAGE, 0.75, 0.4)
	valve.commit(mesh, VALVE, 0.0, 0.7)

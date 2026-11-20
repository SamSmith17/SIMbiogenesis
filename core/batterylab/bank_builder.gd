class_name BankBuilder
extends Node3D

## A battery bank as the BankDesign lays it out: every pack (one pack built
## by BattBuilder, then copied — the copies share its meshes), the cabinet /
## wall / shelf / cart / mat, the busbar pair or distributor box, every cable
## along its measured route in its colour and at its gauge, the string
## fuses and the comms chain. Metres; origin on the floor under the middle.
## Meta "parts" [{id, kind, label, aabb}] for picking (`pick`), "bounds_m".

const MODEL_ID := "batterylab_bank"
const MM := 0.001

var design: Dictionary = {}
var _packs: Array = []
var _hl_node: Node3D = null


static func build_node(bank: Dictionary, node_name: String = "BatteryBank") -> Node3D:
	if bank.is_empty():
		bank = BankSpec.of_pack(BattPresets.builtin("rack_48v_105"), 1, 2)
	var n := build_from_design(BankDesign.solve(bank))
	n.name = node_name
	return n


static func build_from_design(d: Dictionary) -> BankBuilder:
	var b := BankBuilder.new()
	b.design = d
	b._build()
	return b


func _build() -> void:
	var d := design
	var parts: Array = []
	var proto := BattBuilder.build_from_design(d["pack"])
	var pd: Dictionary = d["pack"]
	var pb: AABB = pd["layout"]["bounds"]
	var label := str((pd["spec"] as Dictionary)["name"])
	var root := Node3D.new()
	root.name = "Packs"
	add_child(root)
	for p in (d["packs"] as Array):
		var inst: Node3D = proto if _packs.is_empty() else proto.duplicate() as Node3D
		inst.name = "Pack_%d" % int(p["k"])
		inst.position = (p["pos"] as Vector3) * MM
		root.add_child(inst)
		_packs.append(inst)
		var bb := AABB((pb.position + (p["pos"] as Vector3)) * MM, pb.size * MM)
		parts.append({"id": str(p["id"]), "kind": "pack", "aabb": bb,
			"label": "Pack %d (string %d, %s in series) — %s" % [int(p["k"]) + 1, int(p["string"]) + 1,
				_ord(int(p["place"]) + 1), label]})
	var box := BattBuilder._box_mesh()
	var cyl := BattBuilder._cyl_mesh(10)
	# The frame.
	var fr_mat := {"cabinet": BattBuilder._mat(Color(0.18, 0.19, 0.21), 0.3, 0.6),
		"rail": BattBuilder._mat(Color(0.6, 0.62, 0.65), 0.6, 0.4),
		"wall": BattBuilder._mat(Color(0.82, 0.8, 0.76), 0.0, 0.95),
		"shelf": BattBuilder._mat(Color(0.25, 0.27, 0.3), 0.4, 0.5),
		"cart": BattBuilder._mat(Color(0.2, 0.22, 0.25), 0.4, 0.5),
		"floor": BattBuilder._mat(Color(0.08, 0.08, 0.08), 0.0, 0.95)}
	var frame := Node3D.new()
	frame.name = "Frame"
	add_child(frame)
	for f in (d["frame"]["boxes"] as Array):
		var fb: AABB = f["box"]
		var mi := MeshInstance3D.new()
		mi.name = str(f["id"])
		mi.mesh = box
		mi.material_override = fr_mat.get(str(f["kind"]), fr_mat["shelf"])
		mi.transform = BattBuilder.box_xf(fb.get_center(), fb.size)
		frame.add_child(mi)
		if str(f["kind"]) != "wall":
			parts.append({"id": str(f["id"]), "kind": str(f["kind"]), "label": str(f["label"]),
				"aabb": AABB(fb.position * MM, fb.size * MM)})
	# Wall brackets and cart wheels.
	var mount := str(d["mount"])
	if mount == "wall":
		for p in (d["packs"] as Array):
			var c := (p["pos"] as Vector3) + Vector3(0, -12.0, pb.position.z - 10.0)
			var mi2 := MeshInstance3D.new()
			mi2.mesh = box
			mi2.material_override = fr_mat["rail"]
			mi2.transform = BattBuilder.box_xf(c + Vector3(0, 0, 20), Vector3(pb.size.x * 0.9, 25.0, 60.0))
			frame.add_child(mi2)
	if mount == "cart":
		var deck: AABB = AABB()
		for f in (d["frame"]["boxes"] as Array):
			if str(f["id"]) == "cart_deck":
				deck = f["box"]
		for cx in [deck.position.x + 60.0, deck.end.x - 60.0]:
			for cz in [deck.position.z + 60.0, deck.end.z - 60.0]:
				var w := MeshInstance3D.new()
				w.mesh = cyl
				w.material_override = BattBuilder._mat(Color(0.05, 0.05, 0.05), 0.0, 0.9)
				w.transform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5).scaled(Vector3(0.11, 0.05, 0.11)),
					Vector3(cx, 55.0, cz) * MM)
				frame.add_child(w)
	# The bus.
	var bars: Dictionary = d["bars"]
	var cu := BattBuilder._mat(BattBuilder.C_COPPER, 0.6, 0.35)
	if str(bars["kind"]) == "distributor":
		var dbox: AABB = bars["box"]
		var mi3 := MeshInstance3D.new()
		mi3.name = "Distributor"
		mi3.mesh = box
		mi3.material_override = BattBuilder._mat(Color(0.12, 0.25, 0.5), 0.1, 0.5)
		mi3.transform = BattBuilder.box_xf(dbox.get_center(), dbox.size)
		add_child(mi3)
		parts.append({"id": "distributor", "kind": "bus", "label": "Distributor: every string lands here",
			"aabb": AABB(dbox.position * MM, dbox.size * MM)})
	else:
		for pole in ["pos", "neg"]:
			var line := float(bars["%s_line" % pole])
			var a: Vector3
			var c2: Vector3
			if str(bars["axis"]) == "y":
				a = Vector3(line, float(bars["lo"]) - 40.0, float(bars["z"]))
				c2 = Vector3(line, float(bars["hi"]) + 40.0, float(bars["z"]))
			else:
				a = Vector3(float(bars["lo"]) - 40.0, line, float(bars["z"]))
				c2 = Vector3(float(bars["hi"]) + 40.0, line, float(bars["z"]))
			var mid := (a + c2) * 0.5
			var size := (c2 - a).abs() + Vector3(float(bars["t"]), float(bars["t"]), float(bars["w"]))
			var mi4 := MeshInstance3D.new()
			mi4.name = "Bar_%s" % pole
			mi4.mesh = box
			mi4.material_override = cu
			mi4.transform = BattBuilder.box_xf(mid, size)
			add_child(mi4)
			parts.append({"id": "bar_%s" % pole, "kind": "bus",
				"label": "%s busbar %.0f × %.0f mm" % ["Positive" if pole == "pos" else "Negative", float(bars["w"]), float(bars["t"])],
				"aabb": AABB((mid - size * 0.5) * MM, size * MM)})
	# Cables, red and black, each a chain of cylinders.
	var rows := {"red": [], "black": []}
	for cb in (d["cables"] as Array):
		var dia := BattBuilder._wire_d(float(cb["mm2"]))
		var pts: Array = cb["pts"]
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for i in range(1, pts.size()):
			(rows[str(cb["color"])] as Array).append({"xf": BattBuilder.seg_xf(pts[i - 1], pts[i], dia),
				"color": Color.WHITE})
			lo = lo.min(pts[i - 1]).min(pts[i])
			hi = hi.max(pts[i - 1]).max(pts[i])
		var g := Vector3.ONE * dia
		parts.append({"id": str(cb["id"]), "kind": "cable",
			"label": "%s · %s, %.2f m, %.0f A, %.2f %% drop" % [cb["label"], cb["gauge"], float(cb["len_mm"]) * 0.001,
				float(cb["amps"]), float(cb["drop_pct"])],
			"aabb": AABB((lo - g) * MM, (hi - lo + g * 2.0) * MM)})
	var cables := Node3D.new()
	cables.name = "Cables"
	add_child(cables)
	for col in rows:
		if (rows[col] as Array).is_empty():
			continue
		_multi("Cable_%s" % col, cyl, BattBuilder._mat(BattBuilder.C_RED if col == "red" else BattBuilder.C_BLACK, 0.0, 0.55),
			rows[col], cables)
	# Fuses.
	for f in (d["fuses"] as Array):
		var fp: Vector3 = f["pos"]
		var mi5 := MeshInstance3D.new()
		mi5.name = str(f["id"])
		mi5.mesh = box
		mi5.material_override = BattBuilder._mat(Color(0.95, 0.85, 0.2), 0.1, 0.5)
		mi5.transform = BattBuilder.box_xf(fp, Vector3(70, 40, 40))
		add_child(mi5)
		parts.append({"id": str(f["id"]), "kind": "fuse",
			"label": "%s fuse %.0f A (string %d)" % [str(d["fuse"]["label"]), float(f["amps"]), int(str(f["id"]).get_slice("_", 1)) + 1],
			"aabb": AABB((fp - Vector3(35, 20, 20)) * MM, Vector3(70, 40, 40) * MM)})
	# Comms.
	var crow: Array = []
	for c3 in (d["comms"] as Array):
		crow.append({"xf": BattBuilder.seg_xf(c3["a"], c3["b"], 6.0), "color": Color.WHITE})
	if not crow.is_empty():
		_multi("Comms", cyl, BattBuilder._mat(Color(0.2, 0.45, 0.9), 0.0, 0.6), crow, self)
	set_meta("parts", parts)
	var bnd: AABB = d["bounds"]
	set_meta("bounds_m", AABB(bnd.position * MM, bnd.size * MM))
	set_meta("bank", true)
	# A hidden collision box for the world (PlacedProp reads "CollisionMesh").
	var col_mi := MeshInstance3D.new()
	col_mi.name = "CollisionMesh"
	col_mi.mesh = box
	col_mi.transform = BattBuilder.box_xf(bnd.get_center(), bnd.size)
	col_mi.visible = false
	add_child(col_mi)


func _multi(node_name: String, mesh: Mesh, mat: Material, rows: Array, parent: Node3D) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = rows.size()
	for i in rows.size():
		mm.set_instance_transform(i, rows[i]["xf"])
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.material_override = mat
	parent.add_child(mi)
	return mi


static func _ord(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "%dth" % n
	return "%d%s" % [n, {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")]


func pack_count() -> int:
	return _packs.size()


func pack_node(k: int) -> Node3D:
	return _packs[k] if k >= 0 and k < _packs.size() else null


## Open the packs (lids off) to see the cells.
func set_cutaway(on: bool) -> void:
	for p in _packs:
		var case := (p as Node).find_child("Case", false, false)
		if case != null:
			(case as Node3D).visible = not on


func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for p in (get_meta("parts", []) as Array):
		var hit: Variant = (p["aabb"] as AABB).intersects_ray(origin, dir)
		if hit == null:
			continue
		var t := ((hit as Vector3) - origin).length()
		# Small things win over the packs and the frame they sit on.
		if str(p["kind"]) in ["pack", "cabinet", "shelf", "cart", "rail"]:
			t += 0.03
		if t < best_t:
			best_t = t
			best = p
	return best


func highlight(ids: Array, color: Color = Color(1.0, 0.72, 0.15)) -> void:
	if _hl_node == null:
		_hl_node = Node3D.new()
		_hl_node.name = "Highlight"
		add_child(_hl_node)
	for c in _hl_node.get_children():
		_hl_node.remove_child(c)
		c.queue_free()
	if ids.is_empty():
		return
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.albedo_color = Color(color.r, color.g, color.b, 0.35)
	var box := BattBuilder._box_mesh()
	for p in (get_meta("parts", []) as Array):
		if not ids.has(str(p["id"])):
			continue
		var b: AABB = (p["aabb"] as AABB).grow(0.004)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = m
		mi.transform = Transform3D(Basis.from_scale(b.size), b.get_center())
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hl_node.add_child(mi)


func highlighted_count() -> int:
	return 0 if _hl_node == null else _hl_node.get_child_count()


func part(id: String) -> Dictionary:
	for p in (get_meta("parts", []) as Array):
		if str(p["id"]) == id:
			return p
	return {}

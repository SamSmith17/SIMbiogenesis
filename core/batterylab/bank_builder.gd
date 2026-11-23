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
var _tint_node: Node3D = null


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
	var proto := BattBuilder.build_from_design(d["pack"], true)
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
	# The bus, the fuses, the switch: one merged mesh per finish.
	var bg := BattParts.Geo.new()
	_draw_bus(bg, d, parts)
	_draw_fuses(bg, d, parts)
	_draw_disconnect(bg, d, parts)
	if not bg.is_empty():
		var bus_mi := MeshInstance3D.new()
		bus_mi.name = "Bus"
		bus_mi.mesh = bg.commit()
		add_child(bus_mi)
	# Cables: bent tubes with a lug, washer and nut at each end.
	var cg := BattParts.Geo.new()
	for cb in (d["cables"] as Array):
		var col := BattBuilder.C_RED if str(cb["color"]) == "red" else BattBuilder.C_BLACK
		var path := PackedVector3Array(cb["pts"])
		BattParts.tube(cg, path, float(cb["od"]), col, "jacket", 12)
		for e in (cb["ends"] as Array):
			_cable_end(cg, e, col)
		var g := Vector3.ONE * float(cb["od"])
		var bx := BattBuilder._path_aabb(path)
		parts.append({"id": str(cb["id"]), "kind": "cable",
			"label": "%s · %s, %.2f m, %.0f A, %.2f %% drop%s" % [cb["label"], cb["gauge"], float(cb["len_mm"]) * 0.001,
				float(cb["amps"]), float(cb["drop_pct"]), (" · bent tighter than %.0f mm" % float(cb["r_bend"])) if bool(cb.get("tight", false)) else ""],
			"aabb": bx.grow(g.x * MM * 0.5), "path": BattBuilder._path_m(path), "rad": (float(cb["od"]) * 0.5 + 4.0) * MM})
	if not cg.is_empty():
		var cab := MeshInstance3D.new()
		cab.name = "Cables"
		cab.mesh = cg.commit()
		add_child(cab)
	# Comms: patch cables with RJ45 plugs, a terminator on the last pack.
	var kg := BattParts.Geo.new()
	var blue := Color(0.18, 0.42, 0.85)
	for c3 in (d["comms"] as Array):
		var cp := PackedVector3Array(c3["pts"])
		BattParts.tube(kg, cp, 5.6, blue, "jacket", 8)
		for k in [0, cp.size() - 1]:
			var at: Vector3 = cp[k]
			if k == cp.size() - 1 and bool(c3.get("to_inverter", false)):
				continue
			_rj45(kg, at, blue)
		parts.append({"id": str(c3["id"]), "kind": "comms",
			"label": ("Comms to the inverter" if bool(c3.get("to_inverter", false)) else "Comms, pack %d to %d" % [int(c3["addr"]), int(c3["addr"]) + 1]),
			"aabb": BattBuilder._path_aabb(cp)})
	if not (d["comms"] as Array).is_empty():
		var last: Dictionary = (d["packs"] as Array)[-1]
		var ports: Array = []
		for f in (pd["layout"]["fittings"] as Array):
			if str(f["kind"]) == "port":
				ports.append((f["c"] as Vector3) + Vector3(0, 0, (f["s"] as Vector3).z * 0.5))
		if ports.size() > 1:
			var tp: Vector3 = (last["pos"] as Vector3) + (ports[1] as Vector3)
			_rj45(kg, tp, Color(0.85, 0.75, 0.2))
			parts.append({"id": "terminator", "kind": "comms", "label": "Terminator (the end of the comms chain)",
				"aabb": AABB((tp - Vector3(8, 8, 0)) * MM, Vector3(16, 16, 30) * MM)})
	if not kg.is_empty():
		var cm := MeshInstance3D.new()
		cm.name = "Comms"
		cm.mesh = kg.commit()
		add_child(cm)
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


# ---------------------------------------------------------------------------
# Detail: cable ends, the bus, fuses, the switch, comms plugs (mm)
# ---------------------------------------------------------------------------

const C_STEEL_HW := Color(0.74, 0.75, 0.77)
const C_BRASS := Color(0.86, 0.68, 0.38)
const C_BOARD := Color(0.32, 0.2, 0.11)


## A cable's end: a ring lug with heat-shrink, washer and nut on its stud; a
## clamp round an SAE post; a loose end gets its cap from the tube.
func _cable_end(g: BattParts.Geo, e: Dictionary, col: Color) -> void:
	match str(e.get("kind", "free")):
		"stud":
			var lg: Dictionary = e["lug"]
			if lg.is_empty():
				return
			var p: Vector3 = e["p"]
			var n: Vector3 = e["n"]
			var stud := float(e["stud"])
			BattParts.ring_lug(g, p, n, e["t"], lg, col)
			var top := p + n * float(lg["tongue_t"])
			var wt := BattParts.washer(g, top, n, stud, C_STEEL_HW)
			var nh := BattParts.hex_nut(g, top + n * wt, n, stud, C_STEEL_HW)
			# The stud's end past the nut.
			BattParts.threaded_stud(g, top + n * (wt + nh), n, stud, stud * 0.45, C_STEEL_HW.darkened(0.08))
		"post":
			BattParts.post_clamp(g, e["p"], e["n"], e["t"], BankDesign.POST_R_MM, Color(0.58, 0.58, 0.6))
		_:
			pass


## An RJ45 plug pushed into a port facing +Z, its boot behind it (the
## shared connector kit's "rj45_plug").
func _rj45(g: BattParts.Geo, at: Vector3, boot: Color) -> void:
	ConnectorParts.build(g, "rj45_plug", Transform3D(Basis.IDENTITY, at), {"boot": boot})


## The busbars: each pole's bars laid together, round-ended, on standoff
## insulators off an insulating board, a bolt at every landing; or the
## distributor: a base, two bars inside under a clear cover, studs.
func _draw_bus(g: BattParts.Geo, d: Dictionary, parts: Array) -> void:
	var bars: Dictionary = d["bars"]
	var cu := BattBuilder.C_COPPER
	if str(bars["kind"]) == "distributor":
		var box: AABB = bars["box"]
		var c := box.get_center()
		# Base and cover.
		BattParts.abox(g, Vector3(c.x, c.y, box.position.z + 20.0), Vector3(box.size.x, box.size.y, 40.0),
			Color(0.1, 0.22, 0.48), "plastic")
		BattParts.abox(g, Vector3(c.x, c.y, box.position.z + 70.0), Vector3(box.size.x - 16.0, box.size.y - 16.0, 60.0),
			Color(0.16, 0.3, 0.6), "plastic")
		BattParts.abox(g, Vector3(c.x, c.y, box.end.z - 4.0), Vector3(box.size.x - 10.0, box.size.y - 10.0, 8.0),
			Color(0.1, 0.22, 0.48), "plastic")
		for pole in ["pos", "neg"]:
			var studs: Array = bars["%s_studs" % pole]
			var y := (studs[0] as Vector3).y
			var lo := (studs[0] as Vector3).x - 22.0
			var hi := (studs[-1] as Vector3).x + 22.0
			BattParts.busbar(g, Vector3(lo, y, box.end.z - 4.0), Vector3(hi, y, box.end.z - 4.0), Vector3(0, 0, 1),
				30.0, 6.0, cu, "metal")
			for sp in studs:
				BattParts.threaded_stud(g, sp, Vector3(0, 0, 1), 8.0, 4.0, C_STEEL_HW)
			# A coloured tag at the end of each row.
			BattParts.abox(g, Vector3(hi + 14.0, y, box.end.z), Vector3(12.0, 12.0, 2.0),
				BattBuilder.C_RED if pole == "pos" else BattBuilder.C_BLACK, "plastic")
		parts.append({"id": "distributor", "kind": "bus", "label": "Distributor: every string lands here",
			"aabb": AABB(box.position * MM, box.size * MM)})
		return
	var axis := str(bars["axis"])
	var w := float(bars["w"])
	var t := float(bars["t"])
	var nb := int(bars.get("n", 1))
	var tn := float(bars["tn"])
	var lo := float(bars["lo"]) - BankDesign.BAR_OVERHANG_MM
	var hi := float(bars["hi"]) + BankDesign.BAR_OVERHANG_MM
	var zn := Vector3(0, 0, 1)
	var board_z := float(bars["board_z"])
	var lines := [float(bars["pos_line"]), float(bars["neg_line"])]
	# The board behind both bars; bars on opposite sides of a cabinet each
	# get their own strip.
	var strips: Array = [[minf(lines[0], lines[1]), maxf(lines[0], lines[1])]]
	if bool(bars.get("sides", false)):
		strips = [[lines[0], lines[0]], [lines[1], lines[1]]]
	for si in strips.size():
		var l_lo: float = float(strips[si][0]) - w * 0.5 - 25.0
		var l_hi: float = float(strips[si][1]) + w * 0.5 + 25.0
		var bc: Vector3
		var bs: Vector3
		if axis == "y":
			bc = Vector3((l_lo + l_hi) * 0.5, (lo + hi) * 0.5, board_z - 4.0)
			bs = Vector3(l_hi - l_lo, hi - lo + 40.0, 8.0)
		else:
			bc = Vector3((lo + hi) * 0.5, (l_lo + l_hi) * 0.5, board_z - 4.0)
			bs = Vector3(hi - lo + 40.0, l_hi - l_lo, 8.0)
		BattParts.abox(g, bc, bs, C_BOARD, "board")
		parts.append({"id": "bus_board" if si == 0 else "bus_board_%d" % si, "kind": "bus",
			"label": "Insulating bus board", "aabb": AABB((bc - bs * 0.5) * MM, bs * MM)})
	# The landings and take-offs on each bar (for bolt holes).
	var holes := {"pos": [], "neg": []}
	for cb in (d["cables"] as Array):
		for e in (cb["ends"] as Array):
			if e.is_empty() or str(e.get("kind", "")) != "stud":
				continue
			var p: Vector3 = e["p"]
			for pole in ["pos", "neg"]:
				if absf(p.z - float(bars["face_%s" % pole])) < 1.0 and absf(_across(p, axis) - float(bars["%s_line" % pole])) < w * 0.5 + 1.0:
					(holes[pole] as Array).append(p)
	for f in (d["fuses"] as Array):
		if str(f.get("mount", "")) == "bar":
			(holes["pos"] as Array).append(f["a"])
	var disc: Dictionary = d.get("disconnect", {})
	if not disc.is_empty():
		(holes["pos"] as Array).append(disc["a"])
	for k in 2:
		var pole: String = ["pos", "neg"][k]
		var line: float = lines[k]
		var zc := float(bars["z_%s" % pole])
		var a: Vector3
		var b: Vector3
		if axis == "y":
			a = Vector3(line, lo + w * 0.5, zc)
			b = Vector3(line, hi - w * 0.5, zc)
		else:
			a = Vector3(lo + w * 0.5, line, zc)
			b = Vector3(hi - w * 0.5, line, zc)
		# n bars laid together, a hair apart so each reads.
		for i in nb:
			var off := zn * (-tn * 0.5 + t * (float(i) + 0.5))
			BattParts.busbar(g, a + off, b + off, zn, w, t * 0.97, cu.darkened(0.04 * float(i % 2)), "metal")
		# Standoffs from the bar's back to the board, at the ends and every 300 mm.
		var back := zc - tn * 0.5
		var span := a.distance_to(b)
		var steps := maxi(1, int(ceil(span / 300.0)))
		var ins := Color(0.75, 0.12, 0.1) if pole == "pos" else Color(0.1, 0.1, 0.1)
		for s in steps + 1:
			var q := a.lerp(b, float(s) / float(steps))
			var base := Vector3(q.x, q.y, board_z)
			BattParts.lathe(g, base, zn, [Vector2(0, 0), Vector2(11.0, 0), Vector2(11.0, 2.0), Vector2(9.0, 4.0),
				Vector2(9.0, back - board_z - 3.0), Vector2(11.0, back - board_z - 1.5), Vector2(11.0, back - board_z),
				Vector2(0, back - board_z)], ins, "plastic", 6, true)
		# A bolt head behind each hole.
		for hp in (holes[pole] as Array):
			var hb := Vector3((hp as Vector3).x, (hp as Vector3).y, back)
			BattParts.hex_nut(g, hb, -zn, BankDesign.BAR_STUD_MM, C_STEEL_HW)
		# A polarity tag at the low end.
		var tag := a - (Vector3(0, 1, 0) if axis == "y" else Vector3(1, 0, 0)) * (w * 0.5 + 14.0)
		BattParts.abox(g, tag + zn * (tn * 0.5), Vector3(16.0, 16.0, 2.0), BattBuilder.C_RED if pole == "pos" else BattBuilder.C_BLACK, "plastic")
		var size := (b - a).abs() + Vector3(w, w, tn)
		if axis == "y":
			size = Vector3(w, absf(b.y - a.y) + w, tn)
		else:
			size = Vector3(absf(b.x - a.x) + w, w, tn)
		var mid := (a + b) * 0.5
		parts.append({"id": "bar_%s" % pole, "kind": "bus",
			"label": "%s busbar %s%.0f × %.0f mm, carries %.0f A" % ["Positive" if pole == "pos" else "Negative",
				("%d × " % nb) if nb > 1 else "", w, t, float(bars.get("amps", 0.0))],
			"aabb": AABB((mid - size * 0.5) * MM, size * MM)})


func _across(p: Vector3, axis: String) -> float:
	return p.x if axis == "y" else p.y


## The string fuses as their own hardware: a Class T holder (base, two
## brass blocks, the fuse with its ferrules, a clear cover), an ANL holder
## (a flat fuse with its window), an MRBF terminal block on the pack's
## stud, a MEGA fuse in the distributor.
func _draw_fuses(g: BattParts.Geo, d: Dictionary, parts: Array) -> void:
	var lab := str((d["fuse"] as Dictionary).get("label", "Fuse"))
	for f in (d["fuses"] as Array):
		var type := str(f["type"])
		var a: Vector3 = f["a"]
		var bin: Vector3 = f["in"]
		var n: Vector3 = f["n"]
		var ax: Vector3 = f["axis"]
		var side := n.cross(ax).normalized()
		var dims: Dictionary = BankDesign.FUSE_DIMS.get(type, BankDesign.FUSE_DIMS["class_t"])
		var h := float(dims["h"])
		var wdt := float(dims["w"])
		var pitch := float(dims["pitch"])
		var mid := a + ax * pitch * 0.5
		var bb := AABB()
		match str(f.get("mount", "")):
			"terminal":
				# MRBF: a black block on the stud, its window showing the fuse.
				var c := a + n * h * 0.5 + ax * pitch * 0.5
				BattParts.obox(g, c, ax, n, side, Vector3(pitch + 22.0, h, wdt), Color(0.08, 0.08, 0.08), "plastic")
				BattParts.obox(g, c + n * (h * 0.5 + 0.5), ax, n, side, Vector3(pitch * 0.7, 1.0, wdt * 0.6), Color(0.85, 0.78, 0.3), "plastic")
				BattParts.threaded_stud(g, bin - n * 2.0, n, float(dims["stud"]), 4.0, C_STEEL_HW)
				bb = AABB(c - Vector3.ONE * (pitch + 22.0) * 0.5, Vector3.ONE * (pitch + 22.0))
			"distributor":
				var c2: Vector3 = f["pos"]
				BattParts.obox(g, c2, Vector3(0, 1, 0), n, Vector3(1, 0, 0), Vector3(pitch, 10.0, wdt), Color(0.9, 0.85, 0.75), "plastic")
				BattParts.obox(g, c2 + n * 5.5, Vector3(0, 1, 0), n, Vector3(1, 0, 0), Vector3(pitch * 0.45, 1.0, wdt * 0.7), Color(0.85, 0.15, 0.12), "plastic")
				bb = AABB(c2 - Vector3(wdt, pitch, 12.0) * 0.5, Vector3(wdt, pitch, 12.0))
			_:
				# Base on the bar's face, brass blocks at each end, the fuse between.
				var base_c := mid + n * 5.0
				BattParts.obox(g, base_c, ax, n, side, Vector3(pitch + 30.0, 10.0, wdt), Color(0.1, 0.1, 0.11), "plastic")
				for q in [a, bin - n * h]:
					BattParts.obox(g, (q as Vector3) + n * (10.0 + (h - 10.0) * 0.5), ax, n, side,
						Vector3(24.0, h - 10.0, wdt * 0.6), C_BRASS, "metal")
				var fc := mid + n * (h * 0.55)
				if type == "class_t":
					var r0 := fc - ax * pitch * 0.36
					var r1 := fc + ax * pitch * 0.36
					BattParts.tube(g, PackedVector3Array([r0, r1]), 26.0, Color(0.93, 0.9, 0.82), "plastic", 18)
					for q2 in [r0, r1]:
						BattParts.tube(g, PackedVector3Array([q2 - ax * 7.0, q2 + ax * 7.0]), 28.0, Color(0.8, 0.8, 0.8), "metal", 18)
					# A clear cover over it all.
					BattParts.obox(g, mid + n * (h + 3.0), ax, n, side, Vector3(pitch + 26.0, 2.0, wdt), Color(0.55, 0.6, 0.65), "plastic")
				else:
					BattParts.obox(g, fc, ax, n, side, Vector3(pitch * 0.62, 12.0, 22.0), Color(0.92, 0.92, 0.9), "plastic")
					BattParts.obox(g, fc + n * 6.2, ax, n, side, Vector3(pitch * 0.25, 0.6, 14.0), Color(0.75, 0.8, 0.85), "plastic")
					BattParts.obox(g, fc, ax, n, side, Vector3(pitch * 0.95, 2.0, 18.0), Color(0.85, 0.85, 0.85), "metal")
				# The bar's own bolt end through the output block.
				BattParts.threaded_stud(g, a + n * h, n, float(dims["stud"]), 6.0, C_STEEL_HW)
				BattParts.hex_nut(g, a + n * h, n, float(dims["stud"]), C_STEEL_HW)
				bb = AABB(mid - Vector3.ONE * (pitch + 30.0) * 0.5, Vector3.ONE * (pitch + 30.0))
		parts.append({"id": str(f["id"]), "kind": "fuse",
			"label": "%s fuse %.0f A (string %d)" % [lab, float(f["amps"]), int(str(f["id"]).get_slice("_", 1)) + 1],
			"aabb": AABB(bb.position * MM, bb.size * MM)})


## A rotary battery disconnect switch on the + bar's end: a black body,
## a red key handle on top, its two studs.
func _draw_disconnect(g: BattParts.Geo, d: Dictionary, parts: Array) -> void:
	var disc: Dictionary = d.get("disconnect", {})
	if disc.is_empty():
		return
	var a: Vector3 = disc["a"]
	var n: Vector3 = disc["n"]
	var ax: Vector3 = disc["axis"]
	var side := n.cross(ax).normalized()
	var L := BankDesign.DISCONNECT_W_MM
	var H := BankDesign.DISCONNECT_H_MM
	var c := a + ax * L * 0.5 + n * (H * 0.45)
	BattParts.obox(g, c, ax, n, side, Vector3(L, H * 0.9, 80.0), Color(0.08, 0.08, 0.09), "plastic")
	BattParts.disc(g, c + n * H * 0.45, n, 26.0, 6.0, Color(0.15, 0.15, 0.16), "plastic", 24)
	BattParts.obox(g, c + n * (H * 0.45 + 14.0), side, n, ax, Vector3(48.0, 16.0, 14.0), Color(0.82, 0.1, 0.08), "plastic")
	BattParts.threaded_stud(g, a + n * H * 0.9, n, BankDesign.BAR_STUD_MM, 5.0, C_STEEL_HW)
	BattParts.hex_nut(g, a + n * H * 0.9, n, BankDesign.BAR_STUD_MM, C_STEEL_HW)
	var b: Vector3 = disc["b"]
	BattParts.obox(g, b - n * H * 0.5, ax, n, side, Vector3(22.0, H, 30.0), C_BRASS, "metal")
	var s := Vector3(L, H, 80.0)
	parts.append({"id": "disconnect", "kind": "switch",
		"label": "Battery disconnect switch (%.0f A)" % float(disc["amps"]),
		"aabb": AABB((c - Vector3.ONE * L * 0.5) * MM, Vector3.ONE * L * MM)})


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
		var t: float
		if p.has("path"):
			t = BattBuilder.ray_path_t(origin, dir, p["path"], float(p.get("rad", 0.01)))
			if t == INF:
				continue
		else:
			var hit: Variant = (p["aabb"] as AABB).intersects_ray(origin, dir)
			if hit == null:
				continue
			t = ((hit as Vector3) - origin).length()
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


## Paint a bank-bench frame (BankSim) over the bank: each pack by its
## charge (green full, amber low) or red with its BMS tripped, a blown
## fuse grey. An empty frame takes the paint off.
func show_bench_frame(f: Dictionary) -> void:
	if _tint_node == null:
		_tint_node = Node3D.new()
		_tint_node.name = "BenchTint"
		add_child(_tint_node)
	for c in _tint_node.get_children():
		_tint_node.remove_child(c)
		c.queue_free()
	if f.is_empty():
		return
	var box := BattBuilder._box_mesh()
	var ps: PackedInt32Array = f.get("pack_state", PackedInt32Array())
	var soc: PackedFloat64Array = f.get("pack_soc", PackedFloat64Array())
	var sc: PackedInt32Array = f.get("state_str", PackedInt32Array())
	for p in (get_meta("parts", []) as Array):
		var id := str(p["id"])
		var col := Color(0, 0, 0, 0)
		if str(p["kind"]) == "pack" and id.begins_with("pack_"):
			var k := int(id.get_slice("_", 1))
			if k < ps.size():
				if ps[k] != 0:
					col = Color(0.95, 0.25, 0.2, 0.5)
				else:
					var s := clampf(soc[k], 0.0, 1.0) if k < soc.size() else 0.5
					col = Color(1.0, 0.7, 0.2, 0.32).lerp(Color(0.3, 0.9, 0.4, 0.32), s)
		elif str(p["kind"]) == "fuse" and id.begins_with("fuse_"):
			var j := int(id.get_slice("_", 1))
			if j < sc.size() and sc[j] == 4:
				col = Color(0.15, 0.15, 0.18, 0.85)
		if col.a <= 0.0:
			continue
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = col
		var b: AABB = (p["aabb"] as AABB).grow(0.006)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = m
		mi.transform = Transform3D(Basis.from_scale(b.size), b.get_center())
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_tint_node.add_child(mi)


func tinted_count() -> int:
	return 0 if _tint_node == null else _tint_node.get_child_count()


func highlighted_count() -> int:
	return 0 if _hl_node == null else _hl_node.get_child_count()


func part(id: String) -> Dictionary:
	for p in (get_meta("parts", []) as Array):
		if str(p["id"]) == id:
			return p
	return {}

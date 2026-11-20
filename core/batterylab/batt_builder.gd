class_name BattBuilder
extends Node3D

## Draws a solved battery pack (BattDesign.solve) in metres: cells, studs or
## caps, busbars / nickel / links, the balance harness, main leads, the BMS,
## temperature sensors, holders, compression plates and rods, layer trays,
## the case panels and the front fittings. Lead-acid blocks carry their 2 V
## cells and plates inside, shown in cutaway.
##
## Everything repeated is a MultiMesh of a Godot primitive (BoxMesh,
## CylinderMesh), so winding and normals are the engine's. Each instance
## remembers its assembled transform and an explode direction (a share of
## the pack's largest size), so `set_explode(f)` is a transform rewrite.
##
## Nodes: Cells, Studs, Inner (lead cells + plates), Links, Leads, Harness,
## Bms, Sensors, Frame (holders, trays, plates, rods), Case (panels),
## Fittings. Meta "parts" = [{id, kind, label, aabb}] in local metres for
## picking.

const MODEL_ID := "batterylab_pack"
const MM := 0.001

const C_COPPER := Color(0.86, 0.52, 0.32)
const C_NICKEL := Color(0.78, 0.79, 0.8)
const C_ALU := Color(0.74, 0.76, 0.78)
const C_STEEL := Color(0.55, 0.57, 0.6)
const C_PCB := Color(0.1, 0.34, 0.18)
const C_ABS := Color(0.08, 0.08, 0.09)
const C_RED := Color(0.8, 0.12, 0.1)
const C_BLACK := Color(0.07, 0.07, 0.07)
const C_LEAD := Color(0.42, 0.43, 0.45)
const C_PLATE_POS := Color(0.36, 0.2, 0.12)
const C_PLATE_NEG := Color(0.5, 0.5, 0.52)
const WRAP := {"LFP": Color(0.22, 0.42, 0.82), "NMC": Color(0.42, 0.45, 0.92),
	"FLA": Color(0.18, 0.19, 0.2), "AGM": Color(0.12, 0.12, 0.13), "GEL": Color(0.14, 0.14, 0.16),
	"SLA": Color(0.15, 0.15, 0.16)}
const CASE := {"rack": Color(0.92, 0.92, 0.9), "wall": Color(0.88, 0.89, 0.9),
	"rolling": Color(0.82, 0.83, 0.84), "diy": Color(0.1, 0.1, 0.11), "automotive": Color(0.12, 0.12, 0.13)}

var design: Dictionary = {}
var _items: Array = []      # {mmi, base: Array[Transform3D], dirs: Array[Vector3]}
var _singles: Array = []    # {node, base, dir}
var _explode := 0.0
var _scale := 1.0
var _cutaway := false
var _cells_mmi: MultiMeshInstance3D
var _case_node: Node3D
var _inner_node: Node3D
var _mono_mats: Array = []

static var _mat_cache: Dictionary = {}


## ModelCatalog factory (Phase 5 places packs in the world).
static func build_node(spec: Dictionary, node_name: String = "BatteryPack") -> Node3D:
	var b := build_from_design(BattDesign.solve(spec))
	b.name = node_name
	return b


static func build_from_design(d: Dictionary) -> BattBuilder:
	var b := BattBuilder.new()
	b.design = d
	b._build()
	return b


# ---------------------------------------------------------------------------
# Materials and transforms
# ---------------------------------------------------------------------------

static func _mat(color: Color, metal: float = 0.0, rough: float = 0.7, vcol: bool = false,
		emit: float = 0.0, alpha: float = 1.0) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f|%s|%.2f|%.2f" % [color.to_html(), metal, rough, vcol, emit, alpha]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	if vcol:
		m.vertex_color_use_as_albedo = true
		m.albedo_color = Color.WHITE
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emit
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		m.albedo_color.a = alpha
	_mat_cache[key] = m
	return m


static func box_xf(c_mm: Vector3, s_mm: Vector3) -> Transform3D:
	var s := s_mm * MM
	return Transform3D(Basis.from_scale(Vector3(maxf(s.x, 1e-4), maxf(s.y, 1e-4), maxf(s.z, 1e-4))), c_mm * MM)


## A cylinder (CylinderMesh: radius 0.5, height 1, along +Y) from a to b, mm.
static func seg_xf(a_mm: Vector3, b_mm: Vector3, d_mm: float) -> Transform3D:
	var a := a_mm * MM
	var b := b_mm * MM
	var v := b - a
	var l := v.length()
	if l < 1e-6:
		return Transform3D(Basis.from_scale(Vector3(1e-4, 1e-4, 1e-4)), a)
	var y := v / l
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y).normalized()
	var dm := d_mm * MM
	return Transform3D(Basis(x * dm, y * l, z * dm), (a + b) * 0.5)


static func _cyl_mesh(sides: int = 16) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = 0.5
	cm.bottom_radius = 0.5
	cm.height = 1.0
	cm.radial_segments = sides
	cm.rings = 1
	return cm


static func _box_mesh() -> BoxMesh:
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	return bm


## A MultiMesh node of one primitive; `rows` = [{xf, dir, color}].
func _multi(node_name: String, mesh: Mesh, mat: Material, rows: Array, parent: Node3D = null,
		shadows: bool = true) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = rows.size()
	var base: Array = []
	var dirs: Array = []
	for i in rows.size():
		var r: Dictionary = rows[i]
		mm.set_instance_transform(i, r["xf"])
		# Instance colours reach the shader linear; the palette is sRGB.
		mm.set_instance_color(i, (r.get("color", Color.WHITE) as Color).srgb_to_linear())
		base.append(r["xf"])
		dirs.append(r.get("dir", Vector3.ZERO))
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.material_override = mat
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else self).add_child(mi)
	_items.append({"mmi": mi, "base": base, "dirs": dirs})
	return mi


func _single(node_name: String, mesh: Mesh, mat: Material, xf: Transform3D, dir: Vector3,
		parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xf
	parent.add_child(mi)
	_singles.append({"node": mi, "base": xf, "dir": dir})
	return mi


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	var L: Dictionary = design["layout"]
	var cell: Dictionary = design["cell"]
	var chem := str(design["chem"])
	var sp: Dictionary = design["spec"]
	var bounds: AABB = L["bounds"]
	_scale = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z)) * MM * 0.6
	var parts: Array = []
	var box := _box_mesh()
	var cyl := _cyl_mesh(20)
	var cyl8 := _cyl_mesh(8)
	var wrap := _wrap_color(sp, chem)
	var fmt := str(cell["format"])
	var lp := BattLayout.layer_pitch(L["unit"])
	# Cells.
	var cell_rows: Array = []
	var stud_rows: Array = []
	var cap_rows: Array = []
	for ce in (L["cells"] as Array):
		var c: Vector3 = ce["c"]
		var s: Vector3 = ce["s"]
		var dir := Vector3(0, 0.12 * float(int(ce["layer"])), 0)
		cell_rows.append({"xf": box_xf(c, s) if fmt != "cylindrical" else box_xf(c, s), "dir": dir, "color": wrap})
		parts.append({"id": ce["id"], "kind": "cell", "label": "Cell %d of group %d" % [int(str(ce["id"]).get_slice("_", 2)) + 1, int(ce["group"]) + 1],
			"aabb": AABB((c - s * 0.5) * MM, s * MM)})
		if fmt == "cylindrical":
			var tp: Vector3 = ce["term_p"]
			var tn: Vector3 = ce["term_n"]
			var d := float(s.x)
			var td: Vector3 = ce["term_d"]
			cap_rows.append({"xf": seg_xf(tp - td * 1.2, tp + td * 0.6, d * 0.42), "dir": dir, "color": C_NICKEL})
			cap_rows.append({"xf": seg_xf(tn + td * 1.0, tn - td * 0.4, d * 0.92), "dir": dir, "color": C_STEEL})
		else:
			var td: Vector3 = ce["term_d"]
			var sd := 18.0 if fmt == "monoblock" else 12.0
			var sh := 14.0 if fmt == "monoblock" else BattLayout.STUD_H
			for pair in [[ce["term_p"], C_RED if fmt != "monoblock" else C_LEAD],
					[ce["term_n"], C_BLACK if fmt != "monoblock" else C_LEAD]]:
				var tpt: Vector3 = pair[0]
				stud_rows.append({"xf": seg_xf(tpt - td * sh, tpt + td * (0.5 if fmt != "monoblock" else sh * 0.2), sd),
					"dir": dir, "color": pair[1]})
	var cell_mesh: Mesh = cyl if fmt == "cylindrical" else box
	_cells_mmi = _multi("Cells", cell_mesh, _mat(Color.WHITE, 0.0, 0.45, true), cell_rows)
	if not stud_rows.is_empty():
		_multi("Studs", cyl8, _mat(Color.WHITE, 0.6, 0.4, true), stud_rows)
	if not cap_rows.is_empty():
		_multi("Caps", cyl, _mat(Color.WHITE, 0.7, 0.35, true), cap_rows)
	if fmt == "monoblock":
		_build_monoblock_inside(L, cell, chem)
	# Links and end bars.
	var bar_rows: Array = []
	var cable_rows: Array = []
	for lk in (L["links"] as Array) + (L["ends"] as Array):
		var k := str(lk.get("kind", ""))
		if k == "busbar" or k == "nickel":
			var col := C_NICKEL if k == "nickel" else (C_ALU if str(lk.get("material", "")) == "aluminium" else C_COPPER)
			bar_rows.append({"xf": box_xf(lk["c"], lk["s"]), "dir": lk.get("explode", Vector3.ZERO), "color": col})
			parts.append({"id": lk["id"], "kind": k, "label": ("Nickel strip" if k == "nickel" else "Busbar") + _link_words(lk),
				"aabb": AABB(((lk["c"] as Vector3) - (lk["s"] as Vector3) * 0.5) * MM, (lk["s"] as Vector3) * MM)})
		elif k == "link":
			_poly_rows(cable_rows, lk["pts"], _wire_d(float(lk["area_mm2"])), C_BLACK, Vector3(0, 0.3, 0))
			parts.append({"id": lk["id"], "kind": "link", "label": "Link cable" + _link_words(lk),
				"aabb": _poly_aabb(lk["pts"])})
	if not bar_rows.is_empty():
		_multi("Links", box, _mat(Color.WHITE, 0.55, 0.35, true), bar_rows)
	# Leads.
	for ld in (L["leads"] as Array):
		var col := C_RED if str(ld.get("color", "red")) == "red" else C_BLACK
		_poly_rows(cable_rows, ld["pts"], _wire_d(float(ld["mm2"])), col, ld.get("explode", Vector3(0, 0.5, 0)))
		parts.append({"id": ld["id"], "kind": "lead", "label": "%s cable, %s, %.0f mm" % [
			"Positive" if col == C_RED else "Negative", ld["wire"], float(ld["len_mm"])], "aabb": _poly_aabb(ld["pts"])})
	if not cable_rows.is_empty():
		_multi("Leads", cyl8, _mat(Color.WHITE, 0.0, 0.6, true), cable_rows)
	# Harness.
	var h_rows: Array = []
	for h in (L["harness"] as Array):
		var col := C_BLACK if int(h["i"]) == 0 else Color(0.92, 0.92, 0.9)
		_poly_rows(h_rows, h["pts"], 1.6, col, h.get("explode", Vector3(0, 0.5, 0)))
		parts.append({"id": h["id"], "kind": "tap", "label": "Balance lead B%d, %.0f mm" % [int(h["i"]), float(h["len_mm"])],
			"aabb": _poly_aabb(h["pts"])})
	if not h_rows.is_empty():
		_multi("Harness", cyl8, _mat(Color.WHITE, 0.0, 0.7, true), h_rows, null, false)
	# BMS.
	var bms: Dictionary = L["bms"]
	if not bms.is_empty():
		var bn := Node3D.new()
		bn.name = "Bms"
		add_child(bn)
		_single("Board", box, _mat(C_PCB, 0.1, 0.5), box_xf(bms["c"], bms["s"]), bms["explode"], bn)
		var conn: Vector3 = bms["conn"]
		_single("Connector", box, _mat(Color(0.95, 0.95, 0.92)), box_xf(conn, Vector3(36, 8, 10)), bms["explode"], bn)
		for pad in ["b_neg", "p_neg"]:
			_single(pad, box, _mat(C_COPPER, 0.8, 0.3), box_xf(bms[pad], Vector3(14, 6, 14)), bms["explode"], bn)
		parts.append({"id": "bms", "kind": "bms", "label": str((design["bms"] as Dictionary).get("label", "BMS")),
			"aabb": AABB(((bms["c"] as Vector3) - (bms["s"] as Vector3) * 0.5) * MM, (bms["s"] as Vector3) * MM)})
	var s_rows: Array = []
	for sn in (L["sensors"] as Array):
		s_rows.append({"xf": box_xf(sn["c"], sn["s"]), "dir": sn["explode"], "color": Color(0.95, 0.8, 0.15)})
		parts.append({"id": sn["id"], "kind": "sensor", "label": "Temperature sensor",
			"aabb": AABB(((sn["c"] as Vector3) - (sn["s"] as Vector3) * 0.5) * MM, (sn["s"] as Vector3) * MM)})
	if not s_rows.is_empty():
		_multi("Sensors", box, _mat(Color.WHITE, 0.0, 0.5, true), s_rows)
	# Frame: holders, trays, plates, rods.
	var f_rows: Array = []
	for e in (L["holders"] as Array) + (L["trays"] as Array):
		f_rows.append({"xf": box_xf(e["c"], e["s"]), "dir": e["explode"],
			"color": C_ABS if str(e["kind"]) == "holder" else Color(0.25, 0.25, 0.27)})
		parts.append({"id": e["id"], "kind": e["kind"], "label": "Cell holder" if str(e["kind"]) == "holder" else "Layer tray",
			"aabb": AABB(((e["c"] as Vector3) - (e["s"] as Vector3) * 0.5) * MM, (e["s"] as Vector3) * MM)})
	for e in (L["plates"] as Array):
		f_rows.append({"xf": box_xf(e["c"], e["s"]), "dir": e["explode"], "color": C_ALU})
		parts.append({"id": e["id"], "kind": "plate", "label": "Compression end plate",
			"aabb": AABB(((e["c"] as Vector3) - (e["s"] as Vector3) * 0.5) * MM, (e["s"] as Vector3) * MM)})
	if not f_rows.is_empty():
		_multi("Frame", box, _mat(Color.WHITE, 0.4, 0.5, true), f_rows)
	var r_rows: Array = []
	for r in (L["rods"] as Array):
		r_rows.append({"xf": seg_xf(r["a"], r["b"], float(r["d"])), "dir": r["explode"], "color": C_STEEL})
	if not r_rows.is_empty():
		_multi("Rods", cyl8, _mat(Color.WHITE, 0.8, 0.35, true), r_rows)
	# Case and fittings.
	var en: Dictionary = L["enclosure"]
	_case_node = Node3D.new()
	_case_node.name = "Case"
	add_child(_case_node)
	if not en.is_empty():
		var cc := _case_color(sp)
		var metal := 0.5 if str(en["material"]) == "aluminium" else (0.2 if str(en["material"]) == "steel" else 0.0)
		var cm := _mat(cc, metal, 0.55)
		for pn in (en["panels"] as Array):
			var node := _single(str(pn["id"]), box, cm, box_xf(pn["c"], pn["s"]), pn["explode"], _case_node)
			node.set_meta("panel_kind", str(pn["kind"]))
			parts.append({"id": pn["id"], "kind": "case", "label": "Case " + str(pn["id"]).trim_prefix("case_"),
				"aabb": AABB(((pn["c"] as Vector3) - (pn["s"] as Vector3) * 0.5) * MM, (pn["s"] as Vector3) * MM)})
	var fit := Node3D.new()
	fit.name = "Fittings"
	add_child(fit)
	for f in (L["fittings"] as Array):
		_fitting(fit, f, box, cyl, parts)
	set_meta("parts", parts)
	set_meta("bounds_m", AABB(bounds.position * MM, bounds.size * MM))


func _wrap_color(sp: Dictionary, chem: String) -> Color:
	var w: Array = (sp.get("colors", {}) as Dictionary).get("wrap", []) as Array
	if w.size() >= 3:
		return Color(float(w[0]), float(w[1]), float(w[2]))
	return WRAP.get(chem, Color(0.3, 0.4, 0.8))


func _case_color(sp: Dictionary) -> Color:
	var c: Array = (sp.get("colors", {}) as Dictionary).get("case", []) as Array
	if c.size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return CASE.get(str(sp["form"]), Color(0.2, 0.2, 0.22))


static func _wire_d(mm2: float) -> float:
	return sqrt(maxf(mm2, 0.3) / PI) * 2.0 * 1.5   # conductor + insulation


func _poly_rows(rows: Array, pts: Array, d: float, col: Color, dir: Vector3) -> void:
	for i in range(1, pts.size()):
		rows.append({"xf": seg_xf(pts[i - 1], pts[i], d), "dir": dir, "color": col})
	# Round the corners with a short stub so bends do not show gaps.
	for i in range(1, pts.size() - 1):
		var p: Vector3 = pts[i]
		rows.append({"xf": seg_xf(p - Vector3(0, d * 0.5, 0), p + Vector3(0, d * 0.5, 0), d), "dir": dir, "color": col})


static func _poly_aabb(pts: Array) -> AABB:
	var b := AABB((pts[0] as Vector3) * MM, Vector3.ZERO)
	for p in pts:
		b = b.expand((p as Vector3) * MM)
	return b.grow(0.004)


static func _link_words(lk: Dictionary) -> String:
	if not lk.has("from"):
		return " (pack %s)" % ("negative" if str(lk.get("which", "")) == "neg" else "positive")
	return " joining groups %d and %d" % [int(lk["from"]) + 1, int(lk["to"]) + 1]


func _fitting(parent: Node3D, f: Dictionary, box: Mesh, cyl: Mesh, parts: Array) -> void:
	var k := str(f["kind"])
	var c: Vector3 = f["c"]
	var s: Vector3 = f["s"]
	var dir: Vector3 = f.get("explode", Vector3.ZERO)
	var label := k.capitalize()
	match k:
		"term_pos", "term_neg":
			var col := C_RED if k == "term_pos" else C_BLACK
			_single(str(f["id"]), cyl, _mat(col, 0.2, 0.4), seg_xf(c - Vector3(0, 0, s.z * 0.5), c + Vector3(0, 0, s.z * 0.5), s.x), dir, parent)
			_single(str(f["id"]) + "_stud", cyl, _mat(C_COPPER, 0.8, 0.3), seg_xf(c, c + Vector3(0, 0, s.z * 0.5 + 8.0), 8.0), dir, parent)
			label = "Positive terminal" if k == "term_pos" else "Negative terminal"
		"post_pos", "post_neg":
			_single(str(f["id"]), cyl, _mat(C_LEAD, 0.5, 0.4), seg_xf(c - Vector3(0, s.y * 0.5, 0), c + Vector3(0, s.y * 0.5, 0), s.x), dir, parent)
			_single(str(f["id"]) + "_ring", cyl, _mat(C_RED if k == "post_pos" else C_BLACK, 0.0, 0.5),
				seg_xf(c - Vector3(0, s.y * 0.5, 0), c - Vector3(0, s.y * 0.3, 0), s.x * 1.5), dir, parent)
			label = "Positive post" if k == "post_pos" else "Negative post"
		"wheel":
			_single(str(f["id"]), cyl, _mat(C_BLACK, 0.0, 0.8), seg_xf(c - Vector3(s.x * 0.5, 0, 0), c + Vector3(s.x * 0.5, 0, 0), s.y), dir, parent)
			label = "Caster"
		"breaker":
			_single(str(f["id"]), box, _mat(C_BLACK, 0.0, 0.5), box_xf(c, s), dir, parent)
			_single(str(f["id"]) + "_toggle", box, _mat(Color(0.95, 0.95, 0.92)), box_xf(c + Vector3(0, 0, s.z * 0.5 + 4.0), Vector3(12, 22, 8)), dir, parent)
			label = "Breaker %.0f A" % float(f.get("amps", 0.0))
		"display":
			_single(str(f["id"]), box, _mat(Color(0.15, 0.45, 0.85), 0.0, 0.2, false, 0.8), box_xf(c, s), dir, parent)
			label = "Display"
		"port":
			_single(str(f["id"]), box, _mat(C_STEEL, 0.6, 0.4), box_xf(c, s), dir, parent)
			label = "%s port" % str(f.get("label", ""))
		"shunt":
			_single(str(f["id"]), box, _mat(C_BLACK, 0.0, 0.5), box_xf(c, s), dir, parent)
			_single(str(f["id"]) + "_bar", box, _mat(C_COPPER, 0.8, 0.3), box_xf(c + Vector3(0, s.y * 0.5 + 2.0, 0), Vector3(s.x, 4, 12)), dir, parent)
			label = "Shunt (battery monitor)"
		_:
			var col := C_STEEL
			if k == "ear":
				col = _case_color(design["spec"])
			_single(str(f["id"]), box, _mat(col, 0.5, 0.45), box_xf(c, s), dir, parent)
	parts.append({"id": f["id"], "kind": k, "label": label, "aabb": AABB((c - s * 0.5) * MM, s * MM).grow(0.002)})


## Inside a lead-acid block: its 2 V cells, each a stack of positive (brown
## lead dioxide) and negative (grey sponge lead) plates. Hidden until
## cutaway.
func _build_monoblock_inside(L: Dictionary, cell: Dictionary, _chem: String) -> void:
	_inner_node = Node3D.new()
	_inner_node.name = "Inner"
	add_child(_inner_node)
	var box := _box_mesh()
	var n := BattCells.cells_inside(cell)
	var cell_rows: Array = []
	var plate_rows: Array = []
	var cap_rows: Array = []
	for ce in (L["cells"] as Array):
		var c: Vector3 = ce["c"]
		var s: Vector3 = ce["s"]
		# The long side runs along the terminal line (z before any turn).
		var along_x := s.x > s.z
		var long := s.x if along_x else s.z
		var seg := long / float(n)
		for i in n:
			var off := -long * 0.5 + seg * (float(i) + 0.5)
			var cc := c + (Vector3(off, 0, 0) if along_x else Vector3(0, 0, off))
			var cs := Vector3(seg * 0.92 if along_x else s.x * 0.88, s.y * 0.86, s.z * 0.88 if along_x else seg * 0.92)
			cell_rows.append({"xf": box_xf(cc + Vector3(0, -s.y * 0.04, 0), cs), "color": Color(0.85, 0.85, 0.8, 1)})
			for j in 7:
				var po := -seg * 0.4 + seg * 0.8 * float(j) / 6.0
				var pc := cc + (Vector3(po, -s.y * 0.06, 0) if along_x else Vector3(0, -s.y * 0.06, po))
				var ps := Vector3(2.5 if along_x else s.x * 0.8, s.y * 0.66, s.z * 0.8 if along_x else 2.5)
				plate_rows.append({"xf": box_xf(pc, ps), "color": C_PLATE_POS if j % 2 == 0 else C_PLATE_NEG})
			if bool(BattChem.field(str(cell["chem"]), "vented")):
				cap_rows.append({"xf": seg_xf(cc + Vector3(0, s.y * 0.5, 0), cc + Vector3(0, s.y * 0.5 + 8.0, 0), 26.0),
					"color": C_BLACK})
	_multi("InnerCells", box, _mat(Color.WHITE, 0.0, 0.8, true, 0.0, 0.35), cell_rows, _inner_node, false)
	_multi("Plates", box, _mat(Color.WHITE, 0.3, 0.6, true), plate_rows, _inner_node)
	if not cap_rows.is_empty():
		# Vent caps sit on the lid, outside: they are not hidden with the inside.
		_multi("VentCaps", _cyl_mesh(12), _mat(Color.WHITE, 0.0, 0.6, true), cap_rows)
	_inner_node.visible = false


# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

## 0 = assembled, 1 = fully exploded.
func set_explode(f: float) -> void:
	_explode = clampf(f, 0.0, 1.0)
	var k := _explode * _scale
	for it in _items:
		var mmi: MultiMeshInstance3D = it["mmi"]
		var base: Array = it["base"]
		var dirs: Array = it["dirs"]
		for i in base.size():
			var xf: Transform3D = base[i]
			xf.origin += (dirs[i] as Vector3) * k
			mmi.multimesh.set_instance_transform(i, xf)
	for sg in _singles:
		var xf: Transform3D = sg["base"]
		xf.origin += (sg["dir"] as Vector3) * k
		(sg["node"] as Node3D).transform = xf


func get_explode() -> float:
	return _explode


## Cutaway: the lid, the front and the right side come off; a lead block's
## case turns see-through to show its cells.
func set_cutaway(on: bool) -> void:
	_cutaway = on
	for n in _case_node.get_children():
		var kind := str(n.get_meta("panel_kind", ""))
		(n as Node3D).visible = not on or not (kind == "lid" or kind == "front" or str(n.name) == "case_right")
	if _inner_node != null:
		_inner_node.visible = on
		_cells_mmi.material_override = _mat(Color.WHITE, 0.0, 0.45, true, 0.0, 0.25 if on else 1.0)


func is_cutaway() -> bool:
	return _cutaway


## One colour per cell (in layout order), for colour-by views.
func set_cell_colors(colors: PackedColorArray) -> void:
	var mm := _cells_mmi.multimesh
	for i in mini(colors.size(), mm.instance_count):
		mm.set_instance_color(i, colors[i].srgb_to_linear())


func cell_count() -> int:
	return _cells_mmi.multimesh.instance_count


## The part under a ray in local metres (nearest AABB hit), {} for none.
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for p in (get_meta("parts", []) as Array):
		var b: AABB = p["aabb"]
		if _cutaway and str(p["kind"]) == "case" and (str(p["id"]) in ["case_lid", "case_front", "case_right"]):
			continue
		var hit: Variant = b.intersects_ray(origin, dir)
		if hit == null:
			continue
		var t := ((hit as Vector3) - origin).length()
		# Prefer what is inside the case over the case itself.
		if str(p["kind"]) == "case":
			t += 0.02
		if t < best_t:
			best_t = t
			best = p
	return best


# ---------------------------------------------------------------------------
# Highlight, colour-by, callouts (the designer)
# ---------------------------------------------------------------------------

var _hl_node: Node3D = null


## Amber boxes over the parts named (seen through the case); [] clears.
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
	var box := _box_mesh()
	for p in (get_meta("parts", []) as Array):
		if not ids.has(str(p["id"])):
			continue
		var b: AABB = (p["aabb"] as AABB).grow(0.003)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = m
		mi.transform = Transform3D(Basis.from_scale(b.size), b.get_center())
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hl_node.add_child(mi)


func highlighted_count() -> int:
	return 0 if _hl_node == null else _hl_node.get_child_count()


## The part dict by id ({} when none).
func part(id: String) -> Dictionary:
	for p in (get_meta("parts", []) as Array):
		if str(p["id"]) == id:
			return p
	return {}


## Colour-by modes the designer offers before the BMS simulation exists:
## "part" (the cells' own wrap), "series" (each series group its own hue),
## "parallel" (each cell's place within its group), "voltage" (how far up
## the string each group sits, from the pack's negative to its positive).
const COLOUR_MODES := ["part", "series", "parallel", "voltage"]


func colour_by(mode: String) -> void:
	var L: Dictionary = design["layout"]
	var cells: Array = L["cells"]
	var s := int(design["spec"]["series"])
	var cols := PackedColorArray()
	var wrap := _wrap_color(design["spec"], str(design["chem"]))
	for ce in cells:
		var k := int(ce["group"])
		var i := int(str(ce["id"]).get_slice("_", 2))
		match mode:
			"series":
				cols.append(Color.from_hsv(fmod(float(k) * 0.61803, 1.0), 0.55, 0.9))
			"parallel":
				cols.append(Color.from_hsv(fmod(float(i) * 0.61803 + 0.1, 1.0), 0.5, 0.88))
			"voltage":
				cols.append(voltage_color(float(k) / maxf(float(s - 1), 1.0)))
			_:
				cols.append(wrap)
	set_cell_colors(cols)


## Blue at the pack's negative, through green and yellow to red at its
## positive.
static func voltage_color(t: float) -> Color:
	var u := clampf(t, 0.0, 1.0)
	return Color.from_hsv(lerpf(0.62, 0.0, u), 0.7, 0.92)


## The parts the "Show me" layer labels, in order: [{id, n, title, text, pos}]
## with pos the part's centre in local metres.
func callouts() -> Array:
	var d := design
	var cell: Dictionary = d["cell"]
	var e: Dictionary = d["electrical"]
	var s := int(d["spec"]["series"])
	var p := int(d["spec"]["parallel"])
	var out: Array = []
	var want: Array = [
		["cell_0_0", "A cell", "%s: %.1f V and %.0f Ah. Every cell in the pack is the same." % [cell["label"], float(cell["nominal_v"]), float(cell["ah"])]],
	]
	if p > 1:
		want.append(["cell_0_1", "Cells in parallel", "%d cells side by side share one voltage and add their amp-hours: %d × %.0f Ah = %.0f Ah." % [p, p, float(cell["ah"]), float(e["ah"])]])
	if s > 1:
		var lk := "link_0"
		want.append([lk, "A series link", "Joins one group's negative to the next group's positive, so their voltages add: %d × %.1f V = %.1f V." % [s, float(cell["nominal_v"]), float(e["v_nom"])]])
	if bool(d["protected"]):
		want.append(["tap_B1", "A balance lead", "One thin wire to every joint, so the BMS can read each cell's voltage (%d leads)." % (s + 1)])
		want.append(["bms", "The BMS", "Watches every cell and the current, and opens the charge or discharge switch when something is out of bounds."])
		want.append(["ntc_0", "Temperature sensor", "Lithium must not be charged below freezing; the BMS reads these to know."])
	if not (d["layout"]["terminals"] as Dictionary).is_empty():
		var tid := "term_pos"
		if part(tid).is_empty():
			tid = "post_pos"
		want.append([tid, "Positive terminal", "Where the pack's %.1f V comes out. Up to %.0f A continuous." % [float(e["v_nom"]), float(e["cont_discharge_a"])]])
	if not part("breaker").is_empty():
		want.append(["breaker", "The breaker", "Opens if the current gets dangerously high, and is the pack's off switch."])
	var n := 1
	for w in want:
		var pp := part(str(w[0]))
		if pp.is_empty():
			continue
		out.append({"id": str(w[0]), "n": n, "title": str(w[1]), "text": str(w[2]),
			"pos": (pp["aabb"] as AABB).get_center()})
		n += 1
	return out

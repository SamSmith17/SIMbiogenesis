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
var _terms: Array = []         # every cell terminal: {p, n, dir, stud}
var _kit := false              # prismatic DIY box, drawn as the YIXIANG V3 kit
var _geos: Dictionary = {}     # merged detail meshes by node name + explode
var _lead_routes: Dictionary = {}

static var _mat_cache: Dictionary = {}


## ModelCatalog factory (Phase 5 places packs in the world).
static func build_node(spec: Dictionary, node_name: String = "BatteryPack") -> Node3D:
	var b := build_from_design(BattDesign.solve(spec))
	b.name = node_name
	return b


## `bare_studs`: leave the front terminals' outside washer and nut off (a
## bank puts its own lugs, washers and nuts on them).
static func build_from_design(d: Dictionary, bare_studs: bool = false) -> BattBuilder:
	var b := BattBuilder.new()
	b.design = d
	b.bare_studs = bare_studs
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
	_kit = str(sp["form"]) == "diy" and fmt == "prismatic"
	var lp := BattLayout.layer_pitch(L["unit"])
	# Cells.
	var cell_rows: Array = []
	var stud_rows: Array = []
	var cap_rows: Array = []
	var collar_rows: Array = []
	var vent_rows: Array = []
	var label_rows: Array = []
	var cap_can: Array = []
	var gasket_rows: Array = []
	var sleeve_rows: Array = []
	var mono_hw: Array = []
	_terms = []
	_bar_bolts = []
	_geos = {}
	_lead_routes = {}
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
			collar_rows.append({"xf": unit_xf(tp - td * 1.0, td, d * 0.86, 0.5, d * 0.86), "dir": dir,
				"color": Color(0.85, 0.82, 0.62)})
			# A printed sleeve on the can, clear of the crimp at each end.
			var band_h := clampf(s.y * 0.34, 8.0, 28.0)
			sleeve_rows.append({"xf": box_xf(c + td * s.y * 0.08, Vector3(d * 1.012, band_h, d * 1.012)),
				"dir": dir, "color": Color(0.93, 0.93, 0.9)})
			_terms.append({"p": tp + td * 0.6, "n": td, "dir": dir, "stud": 0.0})
			_terms.append({"p": tn - td * 0.4, "n": -td, "dir": dir, "stud": 0.0})
		elif fmt == "monoblock":
			var td: Vector3 = ce["term_d"]
			for pair in [[ce["term_p"], C_LEAD], [ce["term_n"], C_LEAD]]:
				var tpt: Vector3 = pair[0]
				stud_rows.append({"xf": seg_xf(tpt - td * 14.0, tpt + td * 2.8, 18.0), "dir": dir, "color": pair[1]})
				_terms.append({"p": tpt, "n": td, "dir": dir, "stud": 8.0})
				var top_p := tpt + td * 2.8
				mono_hw.append({"p": top_p, "n": td, "dir": dir})
		else:
			# Prismatic: a film-wrapped can with an aluminium top cap, then an
			# aluminium positive and a copper negative pad, each in a coloured
			# insulating collar, the safety vent between them, a QR label.
			var td: Vector3 = ce["term_d"]
			var ax := td.abs()
			var span := s.dot(ax)
			var cap_t := clampf(span * 0.045, 1.6, 3.4)
			var face := Vector3.ONE - ax
			# A hair off the neighbours so the cans don't fuse into one slab.
			var body_s: Vector3 = s - ax * cap_t - face * 0.7
			var body_c := c - td * cap_t * 0.5
			cell_rows[cell_rows.size() - 1] = {"xf": box_xf(body_c, body_s), "dir": dir, "color": wrap}
			var cap_s: Vector3 = s * face * 0.96 + ax * cap_t
			var cap_c := c + td * (span * 0.5 - cap_t * 0.5)
			cap_can.append({"xf": box_xf(cap_c, cap_s), "dir": dir, "color": Color(0.78, 0.79, 0.81)})
			var g_t := 0.55
			gasket_rows.append({"xf": box_xf(cap_c - td * (cap_t * 0.5 + g_t * 0.35), s * face * 0.985 + ax * g_t),
				"dir": dir, "color": Color(0.08, 0.08, 0.09)})
			var sh := BattLayout.STUD_H
			var pad := minf(18.0, minf(s.x, s.z) * 0.32) if absf(td.y) > 0.5 else minf(18.0, minf(s.x, s.y) * 0.32)
			for pair in [[ce["term_p"], C_ALU, C_RED], [ce["term_n"], C_COPPER, C_BLACK]]:
				var tpt: Vector3 = pair[0]
				stud_rows.append({"xf": seg_xf(tpt - td * sh, tpt, pad), "dir": dir, "color": pair[1]})
				collar_rows.append({"xf": unit_xf(tpt - td * sh, td, pad * 1.35, 1.2, pad * 1.35), "dir": dir, "color": pair[2]})
				_terms.append({"p": tpt, "n": td, "dir": dir, "stud": 6.0})
			var tp: Vector3 = ce["term_p"]
			var tn: Vector3 = ce["term_n"]
			var top := (tp + tn) * 0.5 - td * sh
			var along := (tp - tn)
			along -= td * along.dot(td)
			var gap := along.length()
			if gap > pad * 2.4:
				var al := along / gap
				vent_rows.append({"xf": unit_xf(top, td, maxf(gap - pad * 2.6, 6.0) * 0.55, 0.8, pad * 0.5, al),
					"dir": dir, "color": Color(0.68, 0.7, 0.72)})
				var side := td.cross(al).normalized()
				label_rows.append({"xf": unit_xf(top + side * pad * 1.1, td, gap * 0.42, 0.25, pad * 0.7, al),
					"dir": dir, "color": Color(0.93, 0.93, 0.9)})
	var cell_mesh: Mesh = cyl if fmt == "cylindrical" else box
	# Film wrap and ABS cases are satin, not gloss.
	_cells_mmi = _multi("Cells", cell_mesh, _mat(Color.WHITE, 0.0, 0.62, true), cell_rows)
	if not cap_can.is_empty():
		_multi("CellCaps", box, _mat(Color.WHITE, 0.72, 0.38, true), cap_can)
	if not gasket_rows.is_empty():
		_multi("CellGaskets", box, _mat(Color.WHITE, 0.0, 0.7, true), gasket_rows)
	if not sleeve_rows.is_empty():
		_multi("CellSleeves", cyl, _mat(Color.WHITE, 0.0, 0.55, true), sleeve_rows)
	if not stud_rows.is_empty():
		_multi("Studs", _cyl_mesh(16), _mat(Color.WHITE, 0.75, 0.32, true), stud_rows)
	if not collar_rows.is_empty():
		_multi("Collars", _unit("ring"), _mat(Color.WHITE, 0.0, 0.5, true), collar_rows)
	if not vent_rows.is_empty():
		_multi("Vents", _unit("vent"), _mat(Color.WHITE, 0.7, 0.35, true), vent_rows)
		_multi("CellLabels", _unit("box"), _mat(Color.WHITE, 0.0, 0.7, true), label_rows)
	if not cap_rows.is_empty():
		_multi("Caps", cyl, _mat(Color.WHITE, 0.7, 0.35, true), cap_rows)
	if fmt == "monoblock":
		_build_monoblock_inside(L, cell, chem)
	# Links and end bars.
	var bolt_rows: Array = []
	var washer_rows: Array = []
	var weld_rows: Array = []
	for mh in mono_hw:
		var mp: Vector3 = mh["p"]
		var mn: Vector3 = mh["n"]
		washer_rows.append({"xf": unit_xf(mp, mn, 8.0, 8.0, 8.0), "dir": mh["dir"], "color": Color(0.78, 0.79, 0.8)})
		bolt_rows.append({"xf": unit_xf(mp + mn * 1.44, mn, 8.0, 8.0, 8.0), "dir": mh["dir"], "color": Color(0.7, 0.71, 0.73)})
		_bar_bolts.append({"p": mp, "n": mn, "w": washer_rows.size() - 1, "b": bolt_rows.size() - 1})
	for lk in (L["links"] as Array) + (L["ends"] as Array):
		var k := str(lk.get("kind", ""))
		if k == "busbar" or k == "nickel":
			var col := C_NICKEL if k == "nickel" else (C_ALU if str(lk.get("material", "")) == "aluminium" else C_COPPER)
			var ldir: Vector3 = lk.get("explode", Vector3.ZERO)
			_draw_bar(_geo("Links", ldir), lk, col, k == "nickel")
			_bar_hardware(lk, k == "nickel", ldir, bolt_rows, washer_rows, weld_rows)
			parts.append({"id": lk["id"], "kind": k, "label": ("Nickel strip" if k == "nickel" else "Busbar") + _link_words(lk),
				"aabb": AABB(((lk["c"] as Vector3) - (lk["s"] as Vector3) * 0.5) * MM, (lk["s"] as Vector3) * MM)})
		elif k == "link":
			var path := _link_cable(_geo("LinkCables", Vector3(0, 0.3, 0)), lk, washer_rows, bolt_rows)
			parts.append({"id": lk["id"], "kind": "link", "label": "Link cable" + _link_words(lk),
				"aabb": _path_aabb(path)})
	# Leads.
	for ld in (L["leads"] as Array):
		var col := C_RED if str(ld.get("color", "red")) == "red" else C_BLACK
		var lr := _lead_cable(_geo("Leads", ld.get("explode", Vector3(0, 0.5, 0))), ld, col, L, washer_rows, bolt_rows)
		_lead_routes[str(ld["id"])] = lr
		var flex := float(ld["mm2"]) >= 21.0
		var how := "cable"
		if flex:
			how = "paralleled flexible busbars" if int(BattWire.flex_stack(float(ld["mm2"]))["n"]) == 2 else "flexible busbar"
		parts.append({"id": ld["id"], "kind": "lead", "label": "%s %s, %s, %.0f mm" % [
			"Positive" if col == C_RED else "Negative", how, ld["wire"], float(ld["len_mm"])], "aabb": _path_aabb(lr["path"])})
	# Harness: 22 AWG silicone, soldered to a tab on its joint, bent at
	# three diameters, into the BMS connector.
	for h in (L["harness"] as Array):
		var col := C_BLACK if int(h["i"]) == 0 else Color(0.92, 0.92, 0.9)
		var hg := _geo("Harness", h.get("explode", Vector3(0, 0.5, 0)))
		var hpts := PackedVector3Array(h["pts"])
		var od := BattWire.od_mm("22 AWG")
		var bent := BattWire.bend(hpts, BattWire.bend_r_mm(od, "balance"))
		BattParts.tube(hg, bent["path"], od, col, "jacket", 6)
		if hpts.size() > 1:
			var n0 := _axis_snap(hpts[1] - hpts[0])
			var tdir: Vector3 = BattParts.frame(n0)[0]
			BattParts.plate(hg, hpts[0] - tdir * 3.0, hpts[0] + tdir * 4.0, n0, 6.0, 5.0, 0.4, C_NICKEL, "tin")
			BattParts.disc(hg, hpts[0], n0, 1.8, 1.0, Color(0.7, 0.72, 0.74), "tin", 10)
		parts.append({"id": h["id"], "kind": "tap", "label": "Balance lead B%d, %.0f mm" % [int(h["i"]), float(h["len_mm"])],
			"aabb": _path_aabb(bent["path"])})
	if not washer_rows.is_empty():
		_multi("Washers", _unit("washer"), _mat(Color.WHITE, 0.85, 0.3, true), washer_rows)
	if not bolt_rows.is_empty():
		_multi("Bolts", _unit("bolt"), _mat(Color.WHITE, 0.85, 0.3, true), bolt_rows)
	if not weld_rows.is_empty():
		_multi("Welds", _unit("disc"), _mat(Color.WHITE, 0.6, 0.45, true), weld_rows, null, false)
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
		var bd := BattParts.Geo.new()
		_bms_detail(bd, bms)
		_single("Components", bd.commit(), null, Transform3D.IDENTITY, bms["explode"], bn)
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
	var nut_rows: Array = []
	for r in (L["rods"] as Array):
		var ra: Vector3 = r["a"]
		var rb: Vector3 = r["b"]
		var rd := float(r["d"])
		r_rows.append({"xf": seg_xf(ra, rb, rd), "dir": r["explode"], "color": C_STEEL})
		var rn := (rb - ra).normalized()
		var nh := rd * 0.8
		for end in [ra + rn * nh * 0.55, rb - rn * nh * 0.55]:
			nut_rows.append({"xf": unit_xf(end, rn, rd, rd, rd), "dir": r["explode"], "color": Color(0.62, 0.63, 0.66)})
	if not r_rows.is_empty():
		_multi("Rods", cyl8, _mat(Color.WHITE, 0.8, 0.35, true), r_rows)
	if not nut_rows.is_empty():
		_multi("RodNuts", _unit("nut"), _mat(Color.WHITE, 0.85, 0.32, true), nut_rows)
	# Case and fittings.
	var en: Dictionary = L["enclosure"]
	_case_node = Node3D.new()
	_case_node.name = "Case"
	add_child(_case_node)
	if not en.is_empty():
		var cc := _case_color(sp)
		# Powder-coated steel, bare aluminium, or moulded ABS.
		var mat_name := str(en["material"])
		var metal := 0.55 if mat_name == "aluminium" else (0.06 if mat_name == "steel" else 0.0)
		var rough := 0.4 if mat_name == "aluminium" else (0.46 if mat_name == "steel" else 0.68)
		var cm := _mat(cc, metal, rough)
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
	if not en.is_empty():
		_case_detail(en, L)
	if _kit:
		_yixiang_dress(L)
	_commit_geos()
	set_meta("parts", parts)
	set_meta("lead_routes", _lead_routes)
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
			var g := BattParts.Geo.new()
			_front_terminal(g, f, k == "term_pos")
			_single(str(f["id"]), g.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Positive terminal (M8 stud)" if k == "term_pos" else "Negative terminal (M8 stud)"
		"post_pos", "post_neg":
			var g := BattParts.Geo.new()
			_sae_post(g, f, k == "post_pos")
			_single(str(f["id"]), g.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Positive post (SAE)" if k == "post_pos" else "Negative post (SAE)"
		"wheel":
			_single(str(f["id"]), cyl, _mat(C_BLACK, 0.0, 0.8), seg_xf(c - Vector3(s.x * 0.5, 0, 0), c + Vector3(s.x * 0.5, 0, 0), s.y), dir, parent)
			var wg := BattParts.Geo.new()
			BattParts.disc(wg, c, Vector3.RIGHT, s.y * 0.28, s.x * 0.2, Color(0.55, 0.56, 0.58), "metal", 16)
			BattParts.disc(wg, c, Vector3.LEFT, s.y * 0.28, s.x * 0.2, Color(0.55, 0.56, 0.58), "metal", 16)
			# A fork over the wheel, up to the case.
			var crown := c + Vector3(0, s.y * 0.55, 0)
			BattParts.tube(wg, PackedVector3Array([c + Vector3(s.x * 0.42, 0, 0), crown]), 3.2, C_STEEL, "metal", 8)
			BattParts.tube(wg, PackedVector3Array([c - Vector3(s.x * 0.42, 0, 0), crown]), 3.2, C_STEEL, "metal", 8)
			BattParts.disc(wg, crown + Vector3(0, 2.0, 0), Vector3.UP, 7.0, 3.0, C_STEEL, "metal", 12)
			_single(str(f["id"]) + "_fork", wg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Caster"
		"breaker":
			var body := Color(0.94, 0.94, 0.92) if str(f.get("look", "")) == "yixiang" else C_BLACK
			_single(str(f["id"]), box, _mat(body, 0.0, 0.45), box_xf(c, s), dir, parent)
			_single(str(f["id"]) + "_toggle", box, _mat(Color(0.95, 0.95, 0.92)), box_xf(c + Vector3(0, 0, s.z * 0.5 + 4.0), Vector3(12, 22, 8)), dir, parent)
			var bg := BattParts.Geo.new()
			var face := c + Vector3(0, s.y * 0.28, s.z * 0.5)
			BattParts.abox(bg, face + Vector3(0, 0, 0.35), Vector3(s.x * 0.72, s.y * 0.2, 0.7), Color(0.92, 0.92, 0.88), "plastic")
			BattParts.abox(bg, face + Vector3(0, 0, 0.7), Vector3(s.x * 0.4, 2.2, 0.5), Color(0.15, 0.15, 0.16), "plastic")
			_breaker_studs(bg)
			if not bg.is_empty():
				_single(str(f["id"]) + "_studs", bg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Breaker %.0f A" % float(f.get("amps", 0.0))
		"display":
			_single(str(f["id"]) + "_bezel", box, _mat(Color(0.06, 0.06, 0.07)), box_xf(c - Vector3(0, 0, 0.6), s + Vector3(8, 8, 0.4)), dir, parent)
			_single(str(f["id"]), box, _mat(Color(0.12, 0.38, 0.72), 0.0, 0.25, false, 0.6), box_xf(c, s), dir, parent)
			label = "Display"
		"port":
			_single(str(f["id"]), cyl, _mat(C_STEEL, 0.55, 0.4), seg_xf(c - Vector3(0, 0, s.z * 0.4), c + Vector3(0, 0, s.z * 0.7), minf(s.x, s.y) * 0.85), dir, parent)
			var pg := BattParts.Geo.new()
			BattParts.abox(pg, c - Vector3(0, 0, s.z * 0.2), Vector3(s.x * 1.35, s.y * 1.35, 1.2), Color(0.12, 0.12, 0.13), "plastic")
			_single(str(f["id"]) + "_flange", pg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "%s port" % str(f.get("label", ""))
		"shunt":
			_single(str(f["id"]), box, _mat(C_BLACK, 0.0, 0.5), box_xf(c, s), dir, parent)
			_single(str(f["id"]) + "_bar", box, _mat(C_COPPER, 0.8, 0.3), box_xf(c + Vector3(0, s.y * 0.5 + 2.0, 0), Vector3(s.x, 4, 12)), dir, parent)
			var sg := BattParts.Geo.new()
			for sx in [-1.0, 1.0]:
				var sp := c + Vector3(sx * (s.x * 0.5 - 9.0), s.y * 0.5 + 4.0, 0)
				BattParts.threaded_stud(sg, sp, Vector3.UP, 8.0, 10.0, Color(0.8, 0.8, 0.78))
				BattParts.hex_nut(sg, sp, Vector3.UP, 8.0)
			_single(str(f["id"]) + "_studs", sg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Shunt (battery monitor)"
		"cover":
			_single(str(f["id"]), box, _mat(Color(0.82, 0.9, 0.94), 0.0, 0.08, false, 0.0, 0.3), box_xf(c, s), dir, parent)
			label = "Terminal cover"
		"button":
			_single(str(f["id"]), cyl, _mat(Color(0.16, 0.16, 0.17)), seg_xf(c - Vector3(0, 0, s.z * 0.35), c + Vector3(0, 0, s.z * 0.45), s.x), dir, parent)
			label = "Power button"
		"recess":
			var rg := BattParts.Geo.new()
			BattParts.abox(rg, c, s, Color(0.03, 0.03, 0.04), "plastic")
			var grip := c
			if dir.length() > 0.05:
				grip -= dir.normalized() * 1.2
			BattParts.abox(rg, grip, Vector3(4.0, 9.0, s.z * 0.7), Color(0.14, 0.14, 0.15), "plastic")
			_single(str(f["id"]), rg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Recessed handle"
		"foot":
			_single(str(f["id"]), box, _mat(Color(0.05, 0.05, 0.06), 0.0, 0.55), box_xf(c, s), dir, parent)
			label = "Foot"
		"latch":
			var lg := BattParts.Geo.new()
			BattParts.abox(lg, c, s, Color(0.72, 0.73, 0.76), "metal")
			BattParts.abox(lg, c + Vector3(s.x * 0.2, 0, 0), Vector3(3.0, s.y * 0.45, s.z * 0.4), Color(0.55, 0.56, 0.58), "metal")
			_single(str(f["id"]), lg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Latch"
		"handle":
			var hg := BattParts.Geo.new()
			_grip(hg, c, s, dir)
			_single(str(f["id"]), hg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Handle"
		"ear":
			var ecol := _case_color(design["spec"])
			_single(str(f["id"]), box, _mat(ecol, 0.06, 0.46), box_xf(c, s), dir, parent)
			var eg := BattParts.Geo.new()
			var nslot := 3 if s.y > 80.0 else 2
			for i in nslot:
				var fy := -0.28 + 0.56 * float(i) / float(maxi(nslot - 1, 1))
				BattParts.abox(eg, c + Vector3(0, s.y * fy, s.z * 0.5 + 0.3), Vector3(s.x * 0.42, minf(14.0, s.y * 0.12), 1.0),
					Color(0.08, 0.08, 0.09), "plastic")
			_single(str(f["id"]) + "_slots", eg.commit(), null, Transform3D.IDENTITY, dir, parent)
			label = "Rack ear"
		_:
			_single(str(f["id"]), box, _mat(C_STEEL, 0.5, 0.45), box_xf(c, s), dir, parent)
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
	var strap_rows: Array = []
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
			if i > 0:
				var sc := c + (Vector3(off - seg * 0.5, s.y * 0.38, 0) if along_x else Vector3(0, s.y * 0.38, off - seg * 0.5))
				strap_rows.append({"xf": box_xf(sc, Vector3(seg * 0.5 if along_x else 14.0, 10.0, 14.0 if along_x else seg * 0.5)),
					"color": C_LEAD})
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
	if not strap_rows.is_empty():
		_multi("Straps", box, _mat(Color.WHITE, 0.4, 0.5, true), strap_rows, _inner_node)
	if not cap_rows.is_empty():
		# Vent caps sit on the lid, outside: they are not hidden with the inside.
		_multi("VentCaps", _cyl_mesh(12), _mat(Color.WHITE, 0.0, 0.6, true), cap_rows)
	_inner_node.visible = false


# ---------------------------------------------------------------------------
# Detail: merged meshes, unit hardware, cables, terminals, BMS, case
# ---------------------------------------------------------------------------

var bare_studs := false
var _bar_bolts: Array = []      # {p, n, w (washer row), b (bolt row)} on bars


## The merged mesh for a node name and explode direction.
func _geo(node_name: String, dir: Vector3) -> BattParts.Geo:
	var key := "%s|%.3f,%.3f,%.3f" % [node_name, dir.x, dir.y, dir.z]
	if not _geos.has(key):
		_geos[key] = {"name": node_name, "geo": BattParts.Geo.new(), "dir": dir}
	return _geos[key]["geo"]


func _commit_geos() -> void:
	var used := {}
	for key in _geos:
		var e: Dictionary = _geos[key]
		var g: BattParts.Geo = e["geo"]
		if g.is_empty():
			continue
		var base_nm := str(e["name"])
		var nm := base_nm
		var k := 2
		while used.has(nm):
			nm = "%s%d" % [base_nm, k]
			k += 1
		used[nm] = true
		var mi := _single(nm, g.commit(), null, Transform3D.IDENTITY, e["dir"], self)
		if base_nm == "Harness":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A unit part (y up, base at 0) placed at p (mm) with its y along n,
## scaled sx / sy / sz (mm), its x toward t.
static func unit_xf(p_mm: Vector3, n: Vector3, sx: float, sy: float, sz: float, t: Vector3 = Vector3.ZERO) -> Transform3D:
	var y := n.normalized()
	var x := t - y * t.dot(y)
	if x.length() < 1e-4:
		x = BattParts.frame(y)[0]
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x * sx, y * sy, z * sz), p_mm * MM)


static var _units: Dictionary = {}


## Unit hardware meshes (sized for a 1 mm stud, or a 1 mm part), y up.
static func _unit(kind: String) -> ArrayMesh:
	if _units.has(kind):
		return _units[kind]
	var g := BattParts.Geo.new()
	var w := Color.WHITE
	match kind:
		"nut":
			BattParts.hex_nut(g, Vector3.ZERO, Vector3.UP, 1.0, w)
		"bolt":
			var rc := 0.8 / cos(PI / 6.0)
			BattParts.lathe(g, Vector3.ZERO, Vector3.UP, [Vector2(0, 0), Vector2(rc * 0.95, 0), Vector2(rc, 0.08),
				Vector2(rc, 0.52), Vector2(rc * 0.86, 0.64), Vector2(0, 0.64)], w, "metal", 6, true)
		"washer":
			BattParts.annulus(g, Vector3(0, 0.09, 0), Vector3.UP, 1.05, 0.55, 0.18, w, "metal", 18)
		"disc":
			BattParts.disc(g, Vector3.ZERO, Vector3.UP, 0.5, 1.0, w, "metal", 12)
		"box":
			BattParts.abox(g, Vector3(0, 0.5, 0), Vector3.ONE, w, "plastic")
		"ring":
			BattParts.annulus(g, Vector3(0, 0.5, 0), Vector3.UP, 0.5, 0.36, 1.0, w, "plastic", 20)
		"vent":
			BattParts.busbar(g, Vector3(-0.5, 0.5, 0), Vector3(0.5, 0.5, 0), Vector3.UP, 1.0, 1.0, w, "metal")
	var m := g.commit()
	_units[kind] = m
	return m


## The axis a vector mostly runs along, as a unit vector.
static func _axis_snap(v: Vector3) -> Vector3:
	var a := v.abs()
	if a.y >= a.x and a.y >= a.z:
		return Vector3(0, signf(v.y) if v.y != 0.0 else 1.0, 0)
	if a.z >= a.x:
		return Vector3(0, 0, signf(v.z))
	return Vector3(signf(v.x), 0, 0)


static func _path_aabb(path: PackedVector3Array) -> AABB:
	if path.is_empty():
		return AABB()
	var b := AABB(path[0] * MM, Vector3.ZERO)
	for p in path:
		b = b.expand(p * MM)
	return b.grow(0.004)


## A busbar or nickel strip lying flat on its terminals: round-ended and
## edge-broken for a punched bar, square for a strip; a bar standing across
## an aisle is a block.
func _draw_bar(g: BattParts.Geo, lk: Dictionary, col: Color, nickel: bool) -> void:
	var c: Vector3 = lk["c"]
	var sz: Vector3 = lk["s"]
	var n := _axis_snap(lk.get("n", Vector3.UP))
	var ax := 1 if absf(n.y) > 0.5 else (2 if absf(n.z) > 0.5 else 0)
	var others: Array = []
	for i in 3:
		if i != ax:
			others.append(i)
	var i0 := int(others[0])
	var i1 := int(others[1])
	var i_long := i0 if sz[i0] >= sz[i1] else i1
	var i_w := i1 if i_long == i0 else i0
	var th := sz[ax]
	var w := sz[i_w]
	var ln := sz[i_long]
	if th > w * 0.5:
		BattParts.abox(g, c, sz, col, "metal")
		return
	var t := Vector3.ZERO
	t[i_long] = 1.0
	var half := maxf(ln * 0.5 - w * 0.5, 0.0)
	BattParts.busbar(g, c - t * half, c + t * half, n, w, th, col, "tin" if nickel else "metal", not nickel)


## The hardware where a bar sits on cell terminals: a washer and a bolt per
## threaded terminal, four spot welds per cell under a nickel strip.
func _bar_hardware(lk: Dictionary, nickel: bool, dir: Vector3, bolt_rows: Array, washer_rows: Array,
		weld_rows: Array) -> void:
	var c: Vector3 = lk["c"]
	var sz: Vector3 = lk["s"]
	var n := _axis_snap(lk.get("n", Vector3.UP))
	var th := absf(sz.dot(n))
	var box := AABB(c - sz * 0.5, sz).grow(2.5)
	for tm in _terms:
		var p: Vector3 = tm["p"]
		if not box.has_point(p) or (tm["n"] as Vector3).dot(n) < 0.5:
			continue
		var top := p + n * th
		if nickel:
			var f := BattParts.frame(n)
			for o in [Vector2(-2.2, -1.6), Vector2(2.2, -1.6), Vector2(-2.2, 1.6), Vector2(2.2, 1.6)]:
				weld_rows.append({"xf": unit_xf(top + (f[0] as Vector3) * o.x + (f[1] as Vector3) * o.y, n, 1.3, 0.15, 1.3),
					"dir": dir, "color": Color(0.52, 0.5, 0.47)})
		elif float(tm["stud"]) > 0.0:
			var d := float(tm["stud"])
			washer_rows.append({"xf": unit_xf(top, n, d, d, d), "dir": dir, "color": Color(0.78, 0.79, 0.8)})
			bolt_rows.append({"xf": unit_xf(top + n * d * 0.18, n, d, d, d), "dir": dir, "color": Color(0.7, 0.71, 0.73)})
			_bar_bolts.append({"p": top, "n": n, "w": washer_rows.size() - 1, "b": bolt_rows.size() - 1})


## Where a cable end lands: the face's normal, the stud there, how far the
## lug sits off the point, and whether it gets a nut (a stud) or a bolt
## (a threaded terminal).
func _end_info(p: Vector3, L: Dictionary) -> Dictionary:
	var term: Dictionary = L["terminals"]
	var axis := str(term.get("axis", "z"))
	for k in ["pos", "neg"]:
		if term.has(k) and (term[k] as Vector3).distance_to(p) < 1.0:
			return {"n": Vector3(0, -1, 0) if axis == "y" else Vector3(0, 0, -1), "stud": 8.0, "lift": 0.0,
				"nut": axis != "y"}
	for k in ["breaker_in", "breaker_out"]:
		if term.has(k) and (term[k] as Vector3).distance_to(p) < 1.0:
			return {"n": Vector3(0, 0, -1), "stud": 6.0, "lift": 0.0, "nut": true}
	var bms: Dictionary = L["bms"]
	if not bms.is_empty():
		for k in ["b_neg", "p_neg"]:
			if (bms[k] as Vector3).distance_to(p) < 1.0:
				var c: Vector3 = bms["c"]
				var s: Vector3 = bms["s"]
				var q := (p - c)
				var rel := Vector3(q.x / maxf(s.x, 1.0), q.y / maxf(s.y, 1.0), q.z / maxf(s.z, 1.0))
				var n := _axis_snap(rel)
				return {"n": n, "stud": 6.0, "lift": 3.0, "nut": true}
	for f in (L["fittings"] as Array):
		if str(f["kind"]) == "shunt" and ((f["c"] as Vector3) - Vector3(0, 10, 0)).distance_to(p) < 1.0:
			return {"n": Vector3(0, -1, 0), "stud": 8.0, "lift": 0.0, "nut": true}
	for e in (L["ends"] as Array) + (L["links"] as Array):
		if (e as Dictionary).has("tap") and (e["tap"] as Vector3).distance_to(p) < 1.0:
			return {"n": _axis_snap(e.get("n", Vector3.UP)), "stud": 6.0, "lift": 0.0, "nut": false}
	return {"n": Vector3.UP, "stud": 6.0, "lift": 0.0, "nut": false}


## High-current copper as an insulated flexible busbar. Above about 1/0 the
## stack is two straps, parted along the run and brought together at the lugs.
func _flex_ribbon(g: BattParts.Geo, path: PackedVector3Array, mm2: float, col: Color) -> void:
	if path.size() < 2:
		return
	var st := BattWire.flex_stack(mm2)
	var n := int(st["n"])
	var w := float(st["w"])
	var th := float(st["th"])
	var t0 := (path[1] - path[0]).normalized()
	var up := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.85 else Vector3.FORWARD
	var across := up.cross(t0).normalized()
	var jacket := Color(0.93, 0.36, 0.07) if (_kit or col == C_RED) else Color(0.08, 0.08, 0.09)
	var tape := Color(0.95, 0.78, 0.15)
	var last := path.size() - 1
	for i in n:
		var off := (float(i) - 0.5 * float(n - 1)) * (w + 4.0)
		var shifted := PackedVector3Array()
		for k in path.size():
			var taper := sin(PI * float(k) / float(maxi(last, 1)))
			shifted.append(path[k] + across * off * taper)
		BattParts.ribbon(g, shifted, w, th, jacket, "jacket")
		var into := (shifted[1] - shifted[0]).normalized()
		var back := (shifted[last - 1] - shifted[last]).normalized()
		BattParts.ribbon(g, PackedVector3Array([shifted[0], shifted[0] + into * 14.0]), w, th + 0.7, tape, "plastic")
		BattParts.ribbon(g, PackedVector3Array([shifted[last], shifted[last] + back * 14.0]), w, th + 0.7, tape, "plastic")


## A cable along `corners` (barrel end to barrel end), bent at r, with a
## ring lug at each end given in `ends` [{p, n, t, lug, stud, nut}], each
## lug held by a washer and a nut or bolt. Returns the bend result.
func _cable_geo(g: BattParts.Geo, corners: PackedVector3Array, od: float, r: float, ends: Array, col: Color,
		washer_rows: Array, bolt_rows: Array, dir: Vector3, flex_mm2: float = -1.0) -> Dictionary:
	var bent := BattWire.bend(corners, r)
	if flex_mm2 >= 21.0:
		_flex_ribbon(g, bent["path"], flex_mm2, col)
	else:
		BattParts.tube(g, bent["path"], od, col, "jacket", 12)
	var lug_col := Color(0.78, 0.79, 0.8) if flex_mm2 >= 21.0 else col
	for e in ends:
		var lg: Dictionary = e["lug"]
		if lg.is_empty():
			continue
		var p: Vector3 = e["p"]
		var n: Vector3 = e["n"]
		BattParts.ring_lug(g, p, n, e["t"], lg, lug_col)
		var d := float(e["stud"])
		var tt := float(lg["tongue_t"])
		# A lug on a bar's own bolt lifts that bolt by its tongue.
		var raised := false
		for bb in _bar_bolts:
			if (bb["p"] as Vector3).distance_to(p) < 3.0 and (bb["n"] as Vector3).dot(n) > 0.5:
				for key in ["w", "b"]:
					var rows: Array = washer_rows if key == "w" else bolt_rows
					var xf: Transform3D = rows[int(bb[key])]["xf"]
					xf.origin += n * tt * MM
					rows[int(bb[key])]["xf"] = xf
				raised = true
		if raised:
			continue
		washer_rows.append({"xf": unit_xf(p + n * tt, n, d, d, d), "dir": dir, "color": Color(0.78, 0.79, 0.8)})
		if bool(e.get("nut", false)):
			bolt_rows.append({"xf": unit_xf(p + n * (tt + d * 0.18), n, d, d * 1.15, d), "dir": dir, "color": Color(0.7, 0.71, 0.73)})
		else:
			bolt_rows.append({"xf": unit_xf(p + n * (tt + d * 0.18), n, d, d, d), "dir": dir, "color": Color(0.7, 0.71, 0.73)})
	return bent


## A cell-to-cell link cable: lugs on both terminals, out of each barrel,
## up over the cells in an arch and back down. Close terminals take their
## lugs side by side and loop out to the side.
func _link_cable(g: BattParts.Geo, lk: Dictionary, washer_rows: Array, bolt_rows: Array) -> PackedVector3Array:
	var pts: Array = lk["pts"]
	var a: Vector3 = pts[0]
	var b: Vector3 = pts[pts.size() - 1]
	var na := _axis_snap((pts[1] as Vector3) - a)
	var nb := _axis_snap((pts[pts.size() - 2] as Vector3) - b)
	var mm2 := float(lk["area_mm2"])
	var od := BattWire.od_mm(str(lk.get("wire", "")), mm2)
	var flex := mm2 >= 21.0
	var r := float(BattWire.flex_stack(mm2)["r"]) if flex else BattWire.bend_r_mm(od, "silicone")
	var lg := BattWire.lug(mm2, 6.0)
	var reach := float(lg["reach"])
	var flat_ab := (b - a) - na * (b - a).dot(na)
	var xa: Dictionary
	var xb: Dictionary
	if flat_ab.length() > 2.0 * (reach + r):
		xa = BattWire.lug_exit(a, na, [b], lg)
		xb = BattWire.lug_exit(b, nb, [a], lg)
	else:
		var side := na.cross(flat_ab.normalized() if flat_ab.length() > 0.1 else BattParts.frame(na)[0]).normalized()
		xa = BattWire.lug_exit(a, na, [a + side], lg)
		xb = BattWire.lug_exit(b, nb, [b + side], lg)
	var pa: Vector3 = (xa["s"] as Vector3) + (xa["t"] as Vector3) * r
	var pb: Vector3 = (xb["s"] as Vector3) + (xb["t"] as Vector3) * r
	var up := maxf(r, 20.0)
	var corners := PackedVector3Array([xa["s"], pa, pa + na * up, pb + nb * up, pb, xb["s"]])
	var ends := [{"p": a, "n": na, "t": xa["t"], "lug": lg, "stud": 6.0},
		{"p": b, "n": nb, "t": xb["t"], "lug": lg, "stud": 6.0}]
	var bent := _cable_geo(g, corners, od, r, ends, C_BLACK, washer_rows, bolt_rows, Vector3(0, 0.3, 0),
			mm2 if flex else -1.0)
	return bent["path"]


## A main lead: a ring lug on each end (a terminal stud, a bar, a BMS pad,
## the breaker, the shunt), its gauge's diameter and bend radius, along the
## layout's route moved to leave each barrel straight. The layout's own
## route and length (which set the resistance) are unchanged; this is how it
## really lies. Returns {path, min_r, tight, r, od, length}.
func _lead_cable(g: BattParts.Geo, ld: Dictionary, col: Color, L: Dictionary, washer_rows: Array,
		bolt_rows: Array) -> Dictionary:
	var pts: Array = ld["pts"]
	var a: Vector3 = pts[0]
	var b: Vector3 = pts[pts.size() - 1]
	var ia := _end_info(a, L)
	var ib := _end_info(b, L)
	var mm2 := float(ld["mm2"])
	var od := BattWire.od_mm(str(ld.get("wire", "")), mm2)
	var flex := mm2 >= 21.0
	var r := float(BattWire.flex_stack(mm2)["r"]) if flex else BattWire.bend_r_mm(od, "silicone")
	var interior: Array = pts.slice(1, pts.size() - 1)
	var ta_list: Array = interior.duplicate()
	ta_list.append(b)
	var tb_list: Array = interior.duplicate()
	tb_list.reverse()
	tb_list.append(a)
	var na: Vector3 = ia["n"]
	var nb: Vector3 = ib["n"]
	var pa_pt := a + na * float(ia["lift"])
	var pb_pt := b + nb * float(ib["lift"])
	var lga := BattWire.lug(mm2, float(ia["stud"]))
	var lgb := BattWire.lug(mm2, float(ib["stud"]))
	var xa := BattWire.lug_exit(pa_pt, na, ta_list, lga)
	var xb := BattWire.lug_exit(pb_pt, nb, tb_list, lgb)
	var corners := _lead_corners(xa["s"], xa["t"], xb["s"], xb["t"], interior, a, b, r)
	var ends := [{"p": pa_pt, "n": na, "t": xa["t"], "lug": lga, "stud": ia["stud"], "nut": ia["nut"]},
		{"p": pb_pt, "n": nb, "t": xb["t"], "lug": lgb, "stud": ib["stud"], "nut": ib["nut"]}]
	var bent := _cable_geo(g, corners, od, r, ends, col, washer_rows, bolt_rows, ld.get("explode", Vector3(0, 0.5, 0)),
			mm2 if flex else -1.0)
	bent["od"] = od
	bent["r"] = r
	return bent


## The drawn corners of a lead. The riser and the drop move onto their own
## barrels; each barrel then gets a straight stub no longer than the gap to
## the next corner. A stub of a full bend radius used to run past a close
## corner (the breaker, a layer jumper) and the cable folded back on itself.
func _lead_corners(s: Vector3, ta: Vector3, e: Vector3, tb: Vector3, interior: Array,
		a: Vector3, b: Vector3, r: float) -> PackedVector3Array:
	var mids: Array = []
	for q in interior:
		mids.append(q)
	if mids.size() >= 2:
		mids[0] = _on_barrel(mids[0], a, s)
		mids[mids.size() - 1] = _on_barrel(mids[mids.size() - 1], b, e)
	elif mids.size() == 1:
		mids[0] = _on_barrel(mids[0], a, s)
	var corners := PackedVector3Array()
	corners.append(s)
	if not mids.is_empty():
		var rise: Vector3 = mids[0]
		var rise_ahead := (rise - s).dot(ta)
		var far: Vector3 = mids[1] if mids.size() > 1 else e
		var d1 := 0.0
		if rise_ahead > 1.0:
			d1 = BattWire.stub_len(s, ta, r, rise)
		elif (far - s).dot(ta) > 1.0:
			# The riser sits beside the barrel. Step out toward the next
			# corner and take the riser with the stub, so the turn is a bend.
			d1 = BattWire.stub_len(s, ta, r, far)
			if d1 > 1.0:
				mids[0] = rise + ta * d1
		if d1 > 1.0:
			corners.append(s + ta * d1)
	for q in mids:
		corners.append(q)
	var d2 := BattWire.stub_len(e, tb, r, corners[corners.size() - 1])
	if d2 > 1.0:
		corners.append(e + tb * d2)
	corners.append(e)
	return _drop_folds(corners)


## `p` shares the stud's x or z: that leg is the riser or the drop, so it
## should leave the barrel rather than the stud centre. A cross run that only
## happens to share one coordinate is not this point.
func _on_barrel(p: Vector3, stud: Vector3, barrel: Vector3) -> Vector3:
	var v := p
	if absf(v.x - stud.x) < 0.5:
		v.x = barrel.x
	if absf(v.z - stud.z) < 0.5:
		v.z = barrel.z
	return v


## Drop a corner the cable reaches and immediately leaves backwards.
func _drop_folds(c: PackedVector3Array) -> PackedVector3Array:
	var guard := 0
	while guard < 6:
		guard += 1
		var cut := -1
		for i in range(1, c.size() - 1):
			var d0 := c[i] - c[i - 1]
			var d1 := c[i + 1] - c[i]
			if d0.length() > 0.5 and d1.length() > 0.5 and d0.normalized().dot(d1.normalized()) < -0.25:
				cut = i
				break
		if cut < 0:
			return c
		c.remove_at(cut)
	return c


## On the BMS board's outward face: a finned heat sink, a row of MOSFETs,
## electrolytic capacitors, a controller chip and the current shunt.
func _bms_detail(g: BattParts.Geo, bms: Dictionary) -> void:
	var c: Vector3 = bms["c"]
	var s: Vector3 = bms["s"]
	var ax := 0
	if s.y <= s.x and s.y <= s.z:
		ax = 1
	elif s.z <= s.x:
		ax = 2
	var cb: AABB = design["layout"].get("cells_box", AABB(c, Vector3.ZERO))
	var sgn := 1.0 if (c - cb.get_center())[ax] >= 0.0 else -1.0
	var n := Vector3.ZERO
	n[ax] = sgn
	var o: Array = []
	for i in 3:
		if i != ax:
			o.append(i)
	var iu := int(o[0]) if s[int(o[0])] >= s[int(o[1])] else int(o[1])
	var iw := int(o[1]) if iu == int(o[0]) else int(o[0])
	var u := Vector3.ZERO
	u[iu] = 1.0
	var w := Vector3.ZERO
	w[iw] = 1.0
	var su := s[iu]
	var sw := s[iw]
	if su < 40.0 or sw < 20.0:
		return
	var fc := c + n * s[ax] * 0.5
	# Heat sink: a base plate and fins along one long edge.
	var hl := su * 0.7
	var hw := sw * 0.3
	var hc := fc + w * (sw * 0.5 - hw * 0.5 - 2.0)
	var fh := clampf(sw * 0.18, 5.0, 14.0)
	BattParts.obox(g, hc + n * 0.8, u, n, w, Vector3(hl, 1.6, hw), C_ALU, "metal")
	var nf := clampi(int(hl / 5.0), 4, 24)
	for i in nf:
		var fu := -hl * 0.5 + hl * float(i) / float(nf - 1)
		BattParts.obox(g, hc + u * fu + n * (1.6 + fh * 0.5), u, n, w, Vector3(1.1, fh, hw), C_ALU, "metal")
	# MOSFETs (TO-220: a black body on a metal tab) in a row beside it.
	var nm := clampi(int(su / 14.0), 2, 12)
	var mw := hc - w * (hw * 0.5 + 6.0)
	for i in nm:
		var mu := -su * 0.38 + su * 0.76 * float(i) / float(maxi(nm - 1, 1))
		var mc := mw + u * mu
		BattParts.obox(g, mc + n * 1.4, u, n, w, Vector3(6.0, 2.8, 8.0), Color(0.06, 0.06, 0.07), "plastic")
		BattParts.obox(g, mc + n * 0.4 + w * 5.0, u, n, w, Vector3(6.0, 0.8, 4.0), Color(0.78, 0.79, 0.8), "metal")
	# Capacitors, the controller, the shunt.
	var row := fc - w * (sw * 0.5 - 7.0)
	for i in 3:
		var pc := row + u * (-su * 0.3 + float(i) * 9.0)
		BattParts.disc(g, pc, n, 3.2, 8.0, Color(0.1, 0.2, 0.45), "plastic", 14)
		BattParts.disc(g, pc + n * 8.0, n, 3.0, 0.4, Color(0.82, 0.83, 0.85), "metal", 14)
	BattParts.obox(g, row + u * su * 0.18 + n * 0.8, u, n, w, Vector3(10.0, 1.6, 10.0), Color(0.05, 0.05, 0.06), "plastic")
	BattParts.obox(g, row + u * su * 0.34 + n * 0.6, u, n, w, Vector3(su * 0.12, 1.2, 4.0), C_COPPER, "metal")


## A front terminal: a shrouded insulating boss, the brass terminal, an M8
## stud with washer and nut; inside, the brass block through the panel
## where the lead lands on its own stud; a moulded + or − on the panel.
func _front_terminal(g: BattParts.Geo, f: Dictionary, pos: bool) -> void:
	var c: Vector3 = f["c"]
	var s: Vector3 = f["s"]
	var cc := Vector3(c.x, c.y, c.z - s.z * 0.5)
	ConnectorParts.build(g, "stud", Transform3D(Basis.IDENTITY, cc), {"stud": 8.0, "boss_r": s.x * 0.5,
		"polarity": "+" if pos else "-", "color": C_RED if pos else C_BLACK, "bare": bare_studs, "inner": true})


## An SAE tapered post on the lid, a moulded + or − beside it, the lead
## strap under the lid where the lead lands.
func _sae_post(g: BattParts.Geo, f: Dictionary, pos: bool) -> void:
	var c: Vector3 = f["c"]
	var s: Vector3 = f["s"]
	var base := Vector3(c.x, c.y - s.y * 0.5, c.z)
	BattParts.sae_post(g, base, Vector3.UP, pos, 18.0)
	var col := C_RED if pos else C_BLACK
	var toward := -signf(base.x) if absf(base.x) > 1.0 else 1.0
	var mk := base + Vector3(toward * 22.0, 0.3, 0)
	BattParts.abox(g, mk, Vector3(9.0, 0.6, 2.0), col, "plastic")
	if pos:
		BattParts.abox(g, mk, Vector3(2.0, 0.6, 9.0), col, "plastic")
	BattParts.abox(g, Vector3(c.x, base.y - 8.0, c.z), Vector3(16.0, 16.0, 16.0), C_LEAD, "metal")


## The breaker's two studs inside the front panel.
func _breaker_studs(g: BattParts.Geo) -> void:
	var term: Dictionary = design["layout"]["terminals"]
	var brass := Color(0.84, 0.66, 0.36)
	for k in ["breaker_in", "breaker_out"]:
		if not term.has(k):
			continue
		var p: Vector3 = term[k]
		BattParts.disc(g, p, Vector3(0, 0, 1), 5.0, 22.0, brass, "metal", 14)
		BattParts.threaded_stud(g, p, Vector3(0, 0, -1), 6.0, 9.0, brass.lightened(0.15))


## A grab handle: a bar along the long axis, two feet back toward the case.
func _grip(g: BattParts.Geo, c: Vector3, s: Vector3, out: Vector3) -> void:
	var ax := 0
	if s.y >= s.x and s.y >= s.z:
		ax = 1
	elif s.z >= s.x:
		ax = 2
	var axis := Vector3.ZERO
	axis[ax] = 1.0
	var reach := out
	if reach.length() < 0.05:
		reach = Vector3.UP
	reach = reach.normalized()
	var dia := minf(s[(ax + 1) % 3], s[(ax + 2) % 3])
	var rad := clampf(dia * 0.42, 3.0, 9.0)
	var lift := maxf(rad * 1.6, 12.0)
	var half := maxf(s[ax] * 0.5 - rad, rad)
	var a := c - axis * half + reach * lift
	var b := c + axis * half + reach * lift
	var rubber := Color(0.16, 0.16, 0.17)
	BattParts.tube(g, PackedVector3Array([a, b]), rad * 2.0, rubber, "rubber", 12)
	# Posts run back through the fitting to the case face.
	var ri := 0
	var ra := reach.abs()
	if ra.y >= ra.x and ra.y >= ra.z:
		ri = 1
	elif ra.z >= ra.x:
		ri = 2
	var foot := s[ri] * 0.5 + lift + 3.0
	BattParts.tube(g, PackedVector3Array([a, a - reach * foot]), rad * 1.5, rubber, "plastic", 10)
	BattParts.tube(g, PackedVector3Array([b, b - reach * foot]), rad * 1.5, rubber, "plastic", 10)


## Lid screws, a product label on the front, vent slots, the lid seam.
func _case_detail(en: Dictionary, _L: Dictionary) -> void:
	for pn in (en["panels"] as Array):
		var kind := str(pn["kind"])
		var c: Vector3 = pn["c"]
		var s: Vector3 = pn["s"]
		if kind == "lid" and s.x > 80.0 and s.z > 80.0:
			var g := BattParts.Geo.new()
			var top := c.y + s.y * 0.5
			var spots: Array = []
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					spots.append(Vector3(c.x + sx * (s.x * 0.5 - 10.0), top, c.z + sz * (s.z * 0.5 - 10.0)))
				if s.x > 300.0:
					spots.append(Vector3(c.x, top, c.z + sx * (s.z * 0.5 - 10.0)))
			for sp in spots:
				BattParts.lathe(g, sp, Vector3.UP, [Vector2(0, 0), Vector2(3.6, 0), Vector2(3.4, 0.9), Vector2(2.2, 1.6),
					Vector2(0, 1.8)], Color(0.6, 0.61, 0.63), "metal", 12)
				BattParts.abox(g, sp + Vector3(0, 1.75, 0), Vector3(4.4, 0.5, 0.9), Color(0.2, 0.2, 0.22), "metal")
			# The lid seam: a dark line where the cover meets the body.
			var seam_y := c.y - s.y * 0.5
			var dark := Color(0.12, 0.12, 0.13)
			BattParts.abox(g, Vector3(c.x, seam_y, c.z + s.z * 0.5), Vector3(s.x, 1.3, 1.3), dark, "plastic")
			BattParts.abox(g, Vector3(c.x, seam_y, c.z - s.z * 0.5), Vector3(s.x, 1.3, 1.3), dark, "plastic")
			BattParts.abox(g, Vector3(c.x - s.x * 0.5, seam_y, c.z), Vector3(1.3, 1.3, s.z), dark, "plastic")
			BattParts.abox(g, Vector3(c.x + s.x * 0.5, seam_y, c.z), Vector3(1.3, 1.3, s.z), dark, "plastic")
			var node := _single("lid_screws", g.commit(), null, Transform3D.IDENTITY, pn["explode"], _case_node)
			node.set_meta("panel_kind", "lid")
		elif kind == "front" and not _kit and s.x > 120.0 and s.y > 60.0:
			var g := BattParts.Geo.new()
			var fz := c.z + s.z * 0.5
			var lw := minf(s.x * 0.32, 150.0)
			var lh := minf(s.y * 0.22, 36.0)
			var lc := Vector3(c.x - s.x * 0.28, c.y + s.y * 0.3, fz + 0.2)
			BattParts.abox(g, lc, Vector3(lw, lh, 0.4), Color(0.93, 0.93, 0.9), "plastic")
			BattParts.abox(g, lc + Vector3(-lw * 0.5 + 3.0, 0, 0.1), Vector3(5.0, lh, 0.5), Color(0.15, 0.45, 0.85), "plastic")
			for i in 3:
				BattParts.abox(g, lc + Vector3(4.0, lh * 0.25 - float(i) * lh * 0.22, 0.1),
					Vector3(lw * (0.6 - float(i) * 0.12), 1.6, 0.5), Color(0.3, 0.3, 0.32), "plastic")
			# A bezel just inside the front edge, clear of the terminals.
			var inset := 8.0
			var t := 3.5
			var fz2 := fz + 0.35
			BattParts.abox(g, Vector3(c.x, c.y + s.y * 0.5 - inset, fz2), Vector3(s.x - 4.0, t, 0.8), Color(0.1, 0.1, 0.11), "plastic")
			BattParts.abox(g, Vector3(c.x, c.y - s.y * 0.5 + inset, fz2), Vector3(s.x - 4.0, t, 0.8), Color(0.1, 0.1, 0.11), "plastic")
			BattParts.abox(g, Vector3(c.x - s.x * 0.5 + inset, c.y, fz2), Vector3(t, s.y - inset * 2.0, 0.8), Color(0.1, 0.1, 0.11), "plastic")
			BattParts.abox(g, Vector3(c.x + s.x * 0.5 - inset, c.y, fz2), Vector3(t, s.y - inset * 2.0, 0.8), Color(0.1, 0.1, 0.11), "plastic")
			var node := _single("front_label", g.commit(), null, Transform3D.IDENTITY, pn["explode"], _case_node)
			node.set_meta("panel_kind", "front")
		elif _kit and str(pn["id"]) in ["case_left", "case_right", "case_back"]:
			var yellow := Color(0.93, 0.78, 0.16)
			var g := BattParts.Geo.new()
			var pid := str(pn["id"])
			if pid == "case_back":
				BattParts.abox(g, Vector3(c.x, c.y, c.z + s.z * 0.5 + 1.3), Vector3(s.x - 18.0, s.y - 28.0, 1.4), yellow, "plastic")
			else:
				# Left wall's inner face is +X; the right wall's is −X.
				var sign := 1.0 if pid == "case_left" else -1.0
				BattParts.abox(g, Vector3(c.x + sign * (s.x * 0.5 + 1.3), c.y, c.z),
					Vector3(1.4, s.y - 28.0, s.z * 0.7), yellow, "plastic")
			var sheet := _single(pid + "_liner", g.commit(), null, Transform3D.IDENTITY, pn["explode"], _case_node)
			sheet.set_meta("panel_kind", "right" if pid == "case_right" else "panel")
		elif not _kit and str(pn["id"]) in ["case_left", "case_right"] and s.y > 90.0 and s.z > 40.0:
			var sign := -1.0 if str(pn["id"]) == "case_left" else 1.0
			var face_x := c.x + sign * (s.x * 0.5 + 0.35)
			var nslots := clampi(int(s.y / 32.0), 3, 7)
			var g := BattParts.Geo.new()
			for i in nslots:
				var y := c.y + s.y * (-0.32 + 0.64 * float(i) / float(nslots - 1))
				BattParts.abox(g, Vector3(face_x, y, c.z), Vector3(1.1, 5.5, s.z * 0.62), Color(0.06, 0.06, 0.07), "plastic")
			var node := _single(str(pn["id"]) + "_vents", g.commit(), null, Transform3D.IDENTITY, pn["explode"], _case_node)
			node.set_meta("panel_kind", "right" if sign > 0.0 else "left")


## Green series boards over each row, and a copper strap pairing each pole's
## two studs. The boards sit on the cell caps; the studs come through them.
func _yixiang_dress(L: Dictionary) -> void:
	var g := BattParts.Geo.new()
	var rows := {}
	for ce in (L["cells"] as Array):
		var key := "%d_%d" % [int(ce["layer"]), int(ce["row"])]
		if not rows.has(key):
			rows[key] = []
		(rows[key] as Array).append(ce)
	for key in rows:
		var group: Array = rows[key]
		var td: Vector3 = (group[0] as Dictionary)["term_d"]
		var box := AABB()
		var first := true
		for ce in group:
			var cc: Vector3 = (ce as Dictionary)["c"]
			var ss: Vector3 = (ce as Dictionary)["s"]
			var b := AABB(cc - ss * 0.5, ss)
			box = b if first else box.merge(b)
			first = false
		var face := Vector3.ONE - td.abs()
		var center := box.get_center() + td * (box.size.dot(td.abs()) * 0.5 + 1.0)
		var sz := box.size * face + td.abs() * 2.2 - face * 8.0
		sz.x = maxf(sz.x, 6.0)
		sz.y = maxf(sz.y, 2.0)
		sz.z = maxf(sz.z, 6.0)
		BattParts.abox(g, center, sz, C_PCB, "plastic")
		for ce in group:
			for tp in [(ce as Dictionary)["term_p"], (ce as Dictionary)["term_n"]]:
				BattParts.disc(g, (tp as Vector3) - td * 1.6, td, 8.0, 0.45, Color(0.75, 0.76, 0.78), "metal", 10)
	var term: Dictionary = L["terminals"]
	for pair in [["pos", "pos_twin"], ["neg", "neg_twin"]]:
		if term.has(pair[0]) and term.has(pair[1]):
			BattParts.busbar(g, term[pair[0]], term[pair[1]], Vector3(0, 0, 1), 16.0, 3.0, C_COPPER, "metal", false)
	if not g.is_empty():
		_single("SeriesBoards", g.commit(), null, Transform3D.IDENTITY, Vector3(0, 0.35, 0), self)


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
		var nm := str(n.name)
		var hide := kind == "lid" or kind == "front" or kind == "right" or nm == "case_right" or nm.begins_with("case_right")
		(n as Node3D).visible = not on or not hide
	if _inner_node != null:
		_inner_node.visible = on
		_cells_mmi.material_override = _mat(Color.WHITE, 0.0, 0.62, true, 0.0, 0.25 if on else 1.0)


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

class_name CargoContainerBuilder
extends RefCounted
## Procedural ISO shipping container — PACKING_PLAN.md Phase 1, rebuilt
## 2026-11-07 to read like the real thing: trapezoidal side and end
## corrugation between corner posts, eight corner castings, top and bottom
## rails, a transversely corrugated roof, a plywood floor on cross members
## with forklift pockets through the bottom rails (20' only), and a door end
## with two corrugated leaves, four lock rods with cams, keepers and handles,
## four hinges a leaf and rubber gaskets. Every number is a real ISO 668 /
## ISO 1161 figure or a typical carrier drawing value (named below).
##
## Built as ONE MeshInstance3D ("Mesh") with one surface per material
## (PalletRack pattern) so PlacedProp.setup_collision / pick-AABB consume it
## directly. With `cutaway` the same parts land in SIX MeshInstance3Ds —
## Floor, WallL, WallR, WallFront, Roof, Doors — so the Packing Lab can hide
## the ones between the camera and the load; `doors_open_deg` swings the
## leaves on their hinges (250° folds them back along the sides).
## Local origin: ground centre, floor at local Y = 0, length along Z, the
## doors at +Z. Dims come from ContainerCatalog / IntermodalUnits, so the
## geometry and the packing data can never drift apart.

const MODEL_ID := "cargo_container"

## Paints by name (the first is the default — the reference photo's cargo
## red). `paint` on container_spec / intermodal params picks one; a Color
## is taken as is.
const PAINTS := {
	"red": Color(0.72, 0.11, 0.09),
	"blue": Color(0.10, 0.23, 0.48),
	"green": Color(0.11, 0.35, 0.21),
	"rust": Color(0.50, 0.25, 0.13),
	"orange": Color(0.86, 0.38, 0.10),
	"tan": Color(0.72, 0.61, 0.44),
	"grey": Color(0.40, 0.42, 0.44),
	"white": Color(0.86, 0.86, 0.84),
	"maroon": Color(0.42, 0.09, 0.12),
}
const PAINT_ORDER := ["red", "blue", "green", "rust", "orange", "tan", "grey", "white", "maroon"]
const DEFAULT_PAINT := "red"

## ISO 1161 corner fitting: 178 mm along the length, 162 across, 118 high.
const CAST := Vector3(0.162, 0.118, 0.178)
## Corner post seen from the end (x) and from the side (z).
const POST_X := 0.17
const POST_Z := 0.12
const TOP_RAIL := 0.06
const BOTTOM_RAIL_H := 0.155
const BOTTOM_RAIL_W := 0.05
## Side / end wall corrugation: ~209 mm pitch, 36 mm deep, the crests 12 mm
## behind the post face.
const SIDE_PITCH := 0.209
const SIDE_DEPTH := 0.036
const SIDE_INSET := 0.012
const ROOF_PITCH := 0.21
const ROOF_DEPTH := 0.012
const DOOR_PITCH := 0.21
const DOOR_DEPTH := 0.03
const LEAF_T := 0.05
const LEAF_FRAME := 0.06
## The hinge pins stand this far proud of the corner post's outer faces.
const HINGE_PROUD := 0.03
## Doors folded flat against the sides.
const DOORS_FOLDED_DEG := 270.0
const CROSS_MEMBER_PITCH := 0.305
## Forklift pockets (ISO 668 Annex: 20' only): 355 x 115 mm at 2050 mm centres.
const POCKET_W := 0.355
const POCKET_H := 0.115
const POCKET_CENTRES := 2.05
const GROUPS := ["Floor", "WallL", "WallR", "WallFront", "Roof", "Doors"]

const C_CASTING := Color(0.14, 0.14, 0.15)
const C_GALV := Color(0.72, 0.74, 0.76)
const C_FRAME := Color(0.10, 0.10, 0.11)
const C_PLY := Color(0.52, 0.40, 0.25)
const C_RUBBER := Color(0.05, 0.05, 0.05)
const C_TARP := Color(0.20, 0.32, 0.22)


static func paint_color(v: Variant) -> Color:
	if v is Color:
		return v
	var key := str(v)
	if PAINTS.has(key):
		return PAINTS[key]
	if key.begins_with("#") and key.is_valid_html_color():
		return Color.html(key)
	return PAINTS[DEFAULT_PAINT]


static func build_node(spec: Dictionary = {}, node_name: String = "CargoContainer") -> Node3D:
	var container_id := str(spec.get("container_id", "container_20"))
	var entry := ContainerCatalog.find(container_id)
	if entry.is_empty() or not entry.has("exterior"):
		entry = ContainerCatalog.find("container_20")
		container_id = "container_20"
	var opts := {}
	if spec.has("paint"):
		opts["paint"] = spec["paint"]
	if spec.has("doors_open_deg"):
		opts["doors_open_deg"] = float(spec["doors_open_deg"])
	var root := build_from_entry(entry, node_name, opts)
	root.set_meta("container_spec", {"container_id": container_id,
		"paint": str(spec.get("paint", DEFAULT_PAINT))})
	return root


## An IntermodalUnits / ContainerCatalog container entry (any size, open
## top, flat rack). opts: paint (name | Color), doors_open_deg (0 closed),
## cutaway (one MeshInstance3D per GROUPS entry instead of one "Mesh").
static func build_from_entry(entry: Dictionary, node_name: String = "IntermodalUnit",
		opts: Dictionary = {}) -> Node3D:
	var e: Dictionary = entry.get("exterior", {})
	var l := float(e.get("l_m", 6.058))
	var w := float(e.get("w_m", 2.438))
	var h := float(e.get("h_m", 2.591))
	var inn: Dictionary = entry.get("interior", {})
	var p: Dictionary = entry.get("params", {})
	var paint := paint_color(opts.get("paint", p.get("paint", DEFAULT_PAINT)))
	var b := _Build.new()
	b.l = l
	b.w = w
	b.h = h
	b.int_w = float(inn.get("w_m", w - 0.086))
	b.floor_y = clampf(h - float(inn.get("h_m", h - 0.198)) - 0.03, 0.12, 0.25)
	b.doors_open = deg_to_rad(float(opts.get("doors_open_deg", 0.0)))
	b.paint = paint
	if bool(p.get("flat_rack", false)):
		b.flat_rack()
	else:
		b.shell()
		if bool(p.get("open_top", false)):
			b.tarp()
		else:
			b.roof()
		b.doors()
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("doors_open_deg", float(opts.get("doors_open_deg", 0.0)))
	# Where the load floor is above the ground: the Packing Lab stands its
	# solver frame on it.
	root.set_meta("floor_y", b.floor_y)
	root.set_meta("interior_z0", -(l * 0.5 - POST_Z))
	b.commit(root, bool(opts.get("cutaway", false)))
	return root


## Everything about one container's geometry, grouped by part and material
## so the same emission makes one merged mesh or six cutaway pieces.
class _Build:
	var l := 6.058
	var w := 2.438
	var h := 2.591
	var int_w := 2.352
	var floor_y := 0.168
	var doors_open := 0.0
	var paint := Color(0.72, 0.11, 0.09)
	var _kits: Dictionary = {}       # "group|mat" -> IntermodalMeshKit
	var _mats: Dictionary = {}       # mat key -> Material

	func _k(group: String, mat: String) -> IntermodalMeshKit:
		var key := group + "|" + mat
		if not _kits.has(key):
			_kits[key] = IntermodalMeshKit.new()
		return _kits[key]

	func _mat(key: String) -> Material:
		if _mats.has(key):
			return _mats[key]
		var m: Material
		match key:
			"paint":
				m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, paint)
			"casting":
				m = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, C_CASTING)
			"galv":
				m = StructureMaterials.make(StructureMaterials.Kind.GALVANISED, C_GALV)
			"frame":
				m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, C_FRAME)
			"ply":
				m = StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, C_PLY)
			"rubber":
				m = StructureMaterials.make(StructureMaterials.Kind.RUBBER, C_RUBBER)
			"tarp":
				m = StructureMaterials.make(StructureMaterials.Kind.FABRIC, C_TARP)
			_:
				m = StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, paint)
		_mats[key] = m
		return m

	## One mesh per group (cutaway) or one "Mesh" with every surface.
	func commit(root: Node3D, cutaway: bool) -> void:
		if cutaway:
			for g in GROUPS:
				var mesh := ArrayMesh.new()
				for key in _kits:
					if str(key).begins_with(g + "|"):
						(_kits[key] as IntermodalMeshKit).commit_with(mesh, _mat(str(key).get_slice("|", 1)))
				if mesh.get_surface_count() == 0:
					continue
				var mi := MeshInstance3D.new()
				mi.name = g
				mi.mesh = mesh
				root.add_child(mi)
			return
		# Merged: one surface per material, every group together.
		var merged := ArrayMesh.new()
		var by_mat: Dictionary = {}
		for key in _kits:
			var mk := str(key).get_slice("|", 1)
			if not by_mat.has(mk):
				by_mat[mk] = []
			(by_mat[mk] as Array).append(_kits[key])
		for mk in by_mat:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var any := false
			for kit in by_mat[mk]:
				var k := kit as IntermodalMeshKit
				if k.triangle_count() == 0:
					continue
				st.append_from(k.st.commit(), 0, Transform3D.IDENTITY)
				any = true
			if not any:
				continue
			st.commit(merged)
			merged.surface_set_material(merged.get_surface_count() - 1, _mat(str(mk)))
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = merged
		root.add_child(mi)

	# --- the body ------------------------------------------------------

	## Castings, posts, rails, both side sheets, the front end sheet, the
	## floor on its cross members, the forklift pockets.
	func shell() -> void:
		var c := _k("Floor", "casting")
		var ct := _k("Roof", "casting")
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var x: float = float(sx) * (w - CAST.x) * 0.5
				var z: float = float(sz) * (l - CAST.z) * 0.5
				c.box(Vector3(x, CAST.y * 0.5, z), CAST * 1.01)
				ct.box(Vector3(x, h - CAST.y * 0.5, z), CAST * 1.01)
		# Corner posts: the front pair with the front wall, the rear pair
		# with the doors (they frame the opening when a side wall is hidden).
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var grp := "WallFront" if sz < 0.0 else "Doors"
				_k(grp, "paint").box(
					Vector3(float(sx) * (w - POST_X) * 0.5, h * 0.5, float(sz) * (l - POST_Z) * 0.5),
					Vector3(POST_X, h - 2.0 * CAST.y, POST_Z))
		# Rails.
		var rail_l := l - 2.0 * CAST.z
		var rail_w := w - 2.0 * CAST.x
		for sx in [-1.0, 1.0]:
			_k("Roof", "paint").box(Vector3(float(sx) * (w - TOP_RAIL) * 0.5, h - TOP_RAIL * 0.5, 0.0),
				Vector3(TOP_RAIL, TOP_RAIL, rail_l))
			_k("Floor", "paint").box(
				Vector3(float(sx) * (w - BOTTOM_RAIL_W) * 0.5, 0.015 + BOTTOM_RAIL_H * 0.5, 0.0),
				Vector3(BOTTOM_RAIL_W, BOTTOM_RAIL_H, rail_l))
		# Front top rail + the door header; front bottom rail + the door sill.
		_k("Roof", "paint").box(Vector3(0.0, h - CAST.y * 0.5, -(l - 0.08) * 0.5),
			Vector3(rail_w, CAST.y, 0.08))
		_k("Roof", "paint").box(Vector3(0.0, h - CAST.y * 0.5, (l - 0.08) * 0.5),
			Vector3(rail_w, CAST.y, 0.08))
		_k("Floor", "paint").box(Vector3(0.0, 0.015 + BOTTOM_RAIL_H * 0.5, -(l - 0.08) * 0.5),
			Vector3(rail_w, BOTTOM_RAIL_H, 0.08))
		_k("Floor", "paint").box(Vector3(0.0, 0.015 + BOTTOM_RAIL_H * 0.5, (l - 0.08) * 0.5),
			Vector3(rail_w, BOTTOM_RAIL_H, 0.08))
		# Side sheets: vertical corrugation between the posts.
		var y0 := 0.015 + BOTTOM_RAIL_H
		var wall_h := h - TOP_RAIL - y0
		var span := l - 2.0 * POST_Z
		_corrugated(_k("WallR", "paint"), Vector3((w * 0.5 - SIDE_INSET), y0, -span * 0.5),
			Vector3.BACK, span, Vector3.UP, wall_h, Vector3.RIGHT, SIDE_PITCH, SIDE_DEPTH, 0.04)
		_corrugated(_k("WallL", "paint"), Vector3(-(w * 0.5 - SIDE_INSET), y0, -span * 0.5),
			Vector3.BACK, span, Vector3.UP, wall_h, Vector3.LEFT, SIDE_PITCH, SIDE_DEPTH, 0.04)
		# Front end sheet.
		var ow := w - 2.0 * POST_X
		_corrugated(_k("WallFront", "paint"), Vector3(-ow * 0.5, y0, -(l * 0.5 - SIDE_INSET)),
			Vector3.RIGHT, ow, Vector3.UP, h - CAST.y - y0, Vector3.FORWARD,
			SIDE_PITCH, SIDE_DEPTH, 0.03)
		# Floor: 28 mm plywood on cross members between the bottom rails.
		var fl := l - 2.0 * POST_Z
		_k("Floor", "ply").box(Vector3(0.0, floor_y - 0.014, 0.0), Vector3(int_w, 0.028, fl))
		var fr := _k("Floor", "frame")
		var n := maxi(int(floor(fl / CROSS_MEMBER_PITCH)), 2)
		for i in n + 1:
			var z := -fl * 0.5 + fl * float(i) / float(n)
			fr.box(Vector3(0.0, floor_y - 0.028 - 0.055, z), Vector3(w - 2.0 * BOTTOM_RAIL_W - 0.01, 0.11, 0.045))
		# Forklift pockets through both bottom rails (20' and shorter).
		if l < 7.0:
			for sz in [-1.0, 1.0]:
				fr.box(Vector3(0.0, 0.015 + BOTTOM_RAIL_H * 0.5, float(sz) * POCKET_CENTRES * 0.5),
					Vector3(w + 0.03, POCKET_H, POCKET_W))

	## Transverse shallow corrugation between the top rails.
	func roof() -> void:
		var span := l - 2.0 * POST_Z
		_corrugated(_k("Roof", "paint"), Vector3(-(w * 0.5 - TOP_RAIL), h - ROOF_DEPTH - 0.004, -span * 0.5),
			Vector3.BACK, span, Vector3.RIGHT, w - 2.0 * TOP_RAIL, Vector3.UP,
			ROOF_PITCH, ROOF_DEPTH, 0.03)

	## Open top: a canvas tarp roped over the top rails.
	func tarp() -> void:
		var t := _k("Roof", "tarp")
		t.box(Vector3(0.0, h + 0.02, 0.0), Vector3(w - 0.04, 0.05, l - 0.06))
		var g := _k("Roof", "rubber")
		var n := maxi(int(l / 0.6), 2)
		for i in n:
			var z := -l * 0.5 + l * (float(i) + 0.5) / float(n)
			g.box(Vector3(0.0, h + 0.05, z), Vector3(w + 0.06, 0.02, 0.025))

	## Flat rack: a deep steel deck with a folding end wall at each end.
	func flat_rack() -> void:
		var deck := 0.62
		var k := _k("Floor", "paint")
		k.box(Vector3(0.0, deck * 0.5, 0.0), Vector3(w, deck, l))
		_k("Floor", "ply").box(Vector3(0.0, deck + 0.014, 0.0), Vector3(w - 0.1, 0.028, l - 0.3))
		for sz in [-1.0, 1.0]:
			var zc: float = float(sz) * (l * 0.5 - 0.12)
			var grp := "WallFront" if sz < 0.0 else "Doors"
			_k(grp, "paint").box(Vector3(0.0, deck + (h - deck) * 0.5, zc), Vector3(w, h - deck, 0.24))
			for sx in [-1.0, 1.0]:
				_k(grp, "casting").box(Vector3(float(sx) * (w - CAST.x) * 0.5, h - CAST.y * 0.5, zc), CAST * 1.01)
				_k("Floor", "casting").box(Vector3(float(sx) * (w - CAST.x) * 0.5, CAST.y * 0.5, zc), CAST * 1.01)

	# --- the doors ----------------------------------------------------------

	## Two leaves on the +Z end, each hinged on its corner post. Built in a
	## leaf frame (hinge line = local origin, the leaf running `dir` along X,
	## the outside at local z = 0) and swung by `doors_open` about the hinge.
	func doors() -> void:
		var ow := w - 2.0 * POST_X
		var gap := 0.012
		var lw := ow * 0.5 - gap
		var sill_top := 0.015 + BOTTOM_RAIL_H
		var lh := (h - CAST.y) - sill_top - 0.02
		for side in [-1.0, 1.0]:
			var s := float(side)
			# The hinge pins stand at the corner post's OUTER corner, a little
			# proud, so a leaf swung 270° lies flat against the outside of the
			# side wall (pivoted on the post's inner edge it went through it).
			var hinge := Vector3(s * (w * 0.5 + HINGE_PROUD), sill_top + 0.01, l * 0.5 + HINGE_PROUD)
			var swing := Basis(Vector3.UP, s * doors_open)
			var xf := Transform3D(swing, hinge)
			_leaf(xf, -s, lw, lh, POST_X + HINGE_PROUD)

	## One leaf in its hinge frame: the pin on the local origin, the leaf
	## starting `off` along `dir` (across the post face), its outside at
	## local z = 0 and its thickness toward -z.
	func _leaf(xf: Transform3D, dir: float, lw: float, lh: float, off: float) -> void:
		var paint_k := _k("Doors", "paint")
		var galv := _k("Doors", "galv")
		var rub := _k("Doors", "rubber")
		var saved := [paint_k.xf, galv.xf, rub.xf]
		paint_k.xf = xf
		galv.xf = xf
		rub.xf = xf
		var f := LEAF_FRAME
		var t := LEAF_T
		var x0 := dir * off
		var cx := x0 + dir * lw * 0.5
		# Frame: top, bottom, hinge side, free side.
		paint_k.box(Vector3(cx, lh - f * 0.5, -t * 0.5), Vector3(lw, f, t))
		paint_k.box(Vector3(cx, f * 0.5, -t * 0.5), Vector3(lw, f, t))
		paint_k.box(Vector3(x0 + dir * f * 0.5, lh * 0.5, -t * 0.5), Vector3(f, lh, t))
		paint_k.box(Vector3(x0 + dir * (lw - f * 0.5), lh * 0.5, -t * 0.5), Vector3(f, lh, t))
		# Panel: horizontal corrugation, recessed inside the frame.
		var along := Vector3(dir, 0, 0)
		var o := Vector3(x0 + dir * f, f, -0.012)
		_corrugated(paint_k, o, Vector3.UP, lh - 2.0 * f, along, lw - 2.0 * f, Vector3.BACK,
			DOOR_PITCH, DOOR_DEPTH, 0.02)
		# Lock rods with cams, guide brackets, handles and keepers.
		var handle_y := clampf(1.05, 0.4, lh - 0.4)
		for frac in [0.30, 0.70]:
			var rx := x0 + dir * lw * float(frac)
			galv.cylinder(Vector3(rx, lh * 0.5, 0.045), 0.016, lh - 0.06, Vector3.UP, 12)
			for yy in [0.03, lh - 0.03]:
				galv.box(Vector3(rx, float(yy), 0.04), Vector3(0.05, 0.06, 0.08))
				paint_k.box(Vector3(rx, float(yy), 0.03), Vector3(0.10, 0.07, 0.06))
			for yy in [0.30, lh - 0.30]:
				paint_k.box(Vector3(rx, float(yy), 0.04), Vector3(0.08, 0.05, 0.08))
			# The handle lies toward the free edge, in its retainer.
			var hl := 0.34
			galv.box(Vector3(rx + dir * hl * 0.5, handle_y, 0.07), Vector3(hl, 0.03, 0.03))
			galv.cylinder(Vector3(rx, handle_y, 0.07), 0.028, 0.04, Vector3.BACK, 12)
			paint_k.box(Vector3(rx + dir * (hl - 0.03), handle_y, 0.035), Vector3(0.07, 0.11, 0.07))
		# Hinges: four blades reaching from the leaf's edge across the post
		# face to the pin on the axis.
		var blade := off + 0.06
		for frac2 in [0.10, 0.37, 0.63, 0.90]:
			var hy := lh * float(frac2)
			galv.box(Vector3(dir * blade * 0.5, hy, 0.02), Vector3(blade, 0.10, 0.045))
			galv.cylinder(Vector3(0.0, hy, 0.02), 0.016, 0.15, Vector3.UP, 10)
		# Gaskets: the free edge and the top.
		rub.box(Vector3(x0 + dir * (lw - 0.012), lh * 0.5, -t * 0.5), Vector3(0.024, lh, t + 0.012))
		rub.box(Vector3(cx, lh - 0.008, -t * 0.5), Vector3(lw, 0.016, t + 0.012))
		paint_k.xf = saved[0]
		galv.xf = saved[1]
		rub.xf = saved[2]

	# --- the one corrugation ---------------------------------------------

	## A trapezoidal corrugated sheet. `o` is the panel's corner on its
	## OUTER (crest) plane, `a` the unit axis the flutes repeat along
	## (length `la`), `u` the unit axis each flute runs along (length `lu`),
	## `n` the outward normal; troughs sit `depth` inward. `margin` is a
	## flat strip at each end along `a` (the return into the post). The
	## profile per pitch: crest 28 %, slope 14 %, trough 28 %, slope 14 %,
	## crest 16 % — the look of a Corten side panel.
	func _corrugated(k: IntermodalMeshKit, o: Vector3, a: Vector3, la: float,
			u: Vector3, lu: float, n: Vector3, pitch: float, depth: float, margin: float) -> void:
		var span := la - 2.0 * margin
		if span <= pitch * 0.5:
			k.quad(o, o + a * la, o + a * la + u * lu, o + u * lu, n)
			return
		var count := maxi(int(round(span / pitch)), 1)
		var p := span / float(count)
		var prof := [[0.0, 0.0], [0.28, 0.0], [0.42, 1.0], [0.70, 1.0], [0.84, 0.0], [1.0, 0.0]]
		# End margins on the crest plane.
		if margin > 0.001:
			k.quad(o, o + a * margin, o + a * margin + u * lu, o + u * lu, n)
			var e := o + a * (la - margin)
			k.quad(e, e + a * margin, e + a * margin + u * lu, e + u * lu, n)
		for i in count:
			var base := margin + p * float(i)
			for j in prof.size() - 1:
				var s0 := base + p * float(prof[j][0])
				var s1 := base + p * float(prof[j + 1][0])
				var d0 := depth * float(prof[j][1])
				var d1 := depth * float(prof[j + 1][1])
				var p0 := o + a * s0 - n * d0
				var p1 := o + a * s1 - n * d1
				# Outward normal of the segment in the (a, n) plane.
				var nn := (n * (s1 - s0) + a * (d1 - d0)).normalized()
				k.quad(p0, p1, p1 + u * lu, p0 + u * lu, nn)

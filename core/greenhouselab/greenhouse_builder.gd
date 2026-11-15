class_name GreenhouseBuilder
extends RefCounted

## Draws a GreenhouseDesign (the shell; the beds, gantries and light racks are
## their own props, mounted on it):
##  - "Mesh": frame, opaque walls, earth walls below grade, barrels, gutters,
##    cistern, fan housings, floor — one surface per material, no collision;
##  - "Glazing": the glazing, see-through, casting no shadow, no collision;
##  - "Shade": the shade cloth when the design has one;
##  - "Doors/D<i>", "Vents/<kind><i>", "Fans/F<i>/Blades": nodes the runtime
##    moves (`set_vents`, `set_doors`, `spin_fans`);
##  - "CollisionMesh" (hidden): floor, walls and roof with the doorways open.
## A dome form is DomeLab's geodesic (child "Dome") with the same extras.
## Metas: `greenhouse_spec`, `size_m`, `vent_nodes`, `fan_nodes`.
## Every emitter is EarthshipBuilder's (triangles wound to their normals).

const MODEL_ID := "greenhouse_structure"

const COLORS := {
	"floor": Color(0.55, 0.50, 0.44),
	"earth_wall": Color(0.60, 0.56, 0.50),
	"barrel_black": Color(0.07, 0.07, 0.08),
	"barrel_blue": Color(0.13, 0.27, 0.62),
	"gutter": Color(0.78, 0.79, 0.80),
	"cistern": Color(0.20, 0.22, 0.24),
	"fan": Color(0.62, 0.64, 0.66),
	"heater": Color(0.55, 0.18, 0.12),
	"door": Color(0.35, 0.36, 0.38),
	"controller": Color(0.92, 0.92, 0.88),
	"shade": Color(0.05, 0.06, 0.05),
}
const VENT_MAX_DEG := 38.0


static func build_node(spec_in: Variant, node_name: String = "Greenhouse", opts: Dictionary = {}) -> Node3D:
	var spec: Dictionary = spec_in if spec_in is Dictionary else {}
	return build_from_design(GreenhouseDesign.solve(spec), node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "Greenhouse", opts: Dictionary = {}) -> Node3D:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	var root := Node3D.new()
	root.name = node_name
	var kit := {"tools": {}, "glaze": {}, "col": _st(), "shade": _st(), "shade_n": 0}
	var cutaway := bool(opts.get("cutaway", false))
	if str(fr["form"]) == "dome":
		_build_dome(root, d, kit, cutaway)
	else:
		_build_tunnel(root, d, kit, cutaway)
	_build_common(root, d, kit)
	_commit(root, s, kit)
	root.set_meta(GreenhouseSpec.KEY, s)
	var st: Dictionary = d["stats"]
	root.set_meta("size_m", Vector3(float(s["length_m"]), float(st["height_m"]), float(s["width_m"])))
	return root


# --- tunnel forms -------------------------------------------------------------

static func _build_tunnel(root: Node3D, d: Dictionary, kit: Dictionary, cutaway: bool) -> void:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	var prof: PackedVector2Array = fr["profile"]
	var hl := float(s["length_m"]) * 0.5
	var sink := float(s["ground"]["sink_m"])
	var fm := GreenhouseMaterials.frame(str(s["frame"]))
	var r := float(fm["od_mm"]) * 0.0005
	var ftool := _tool(kit, "frame")
	for rib in fr["ribs"]:
		var pts: PackedVector3Array = rib
		for i in pts.size() - 1:
			EarthshipBuilder.emit_cyl(ftool, pts[i], pts[i + 1], r, 6)
	for p in fr["purlins"]:
		EarthshipBuilder.emit_cyl(ftool, p[0], p[1], r * 0.8, 6)
	# Long faces: glazing (or an opaque wall / earth), whole length.
	var off := r + 0.006
	for f in fr["faces"]:
		var fd: Dictionary = f
		var poly: PackedVector3Array = fd["poly"]
		if poly.size() != 4 or str(fd["kind"]) in ["end", "door"]:
			continue
		var n: Vector3 = fd["normal"]
		var q := PackedVector3Array()
		for v in poly:
			q.append(v + n * off)
		if cutaway and str(fd["kind"]) == "roof":
			continue
		if bool(fd["glazed"]):
			EarthshipBuilder.emit_quad(_glaze(kit, str(fd["material"])), q[0], q[1], q[2], q[3])
			if str(fd["kind"]) == "roof" and float(s["shade"]["cloth"]) > 0.0:
				var q2: Array = []
				for v2 in q:
					q2.append(v2 + n * 0.05)
				EarthshipBuilder.emit_quad(kit["shade"], q2[0], q2[1], q2[2], q2[3])
				kit["shade_n"] = int(kit["shade_n"]) + 1
		else:
			var mat := "earth_wall" if str(fd["kind"]) == "earth" else "wall_" + str(fd["material"])
			EarthshipBuilder.emit_quad(_tool(kit, mat), q[0], q[1], q[2], q[3])
		EarthshipBuilder.emit_quad(kit["col"], q[0], q[1], q[2], q[3])
	# End walls: the profile closed by the floor, the doorway cut out, earth
	# below grade.
	var door_w := float(s["doors"]["w_m"])
	var ends_mat := str(s["glazing"]["ends"])
	for door_end: float in [-1.0, 1.0]:
		var x := door_end * (hl + off)
		var has_door := false
		var door_h := 0.0
		for dr in fr["doors"]:
			if signf(float((dr as Dictionary)["x"])) == door_end:
				has_door = true
				door_h = float(dr["h_m"])
		var polys: Array = [prof]
		if has_door:
			var rect := PackedVector2Array([Vector2(-door_w * 0.5, -1.0), Vector2(door_w * 0.5, -1.0),
				Vector2(door_w * 0.5, door_h), Vector2(-door_w * 0.5, door_h)])
			polys = Geometry2D.clip_polygons(prof, rect)
		for pg in polys:
			var poly2: PackedVector2Array = pg
			for part in _split_poly_at(poly2, sink):
				var below: bool = part[1]
				var pp: PackedVector2Array = part[0]
				var st: SurfaceTool = null
				if below:
					st = _tool(kit, "earth_wall")
				elif ends_mat == "stud":
					st = _tool(kit, "wall_stud_insulated")
				else:
					st = _glaze(kit, ends_mat)
				_emit_poly_x(st, pp, x, door_end)
				_emit_poly_x(kit["col"], pp, x, door_end)
		# The door frame and the door, hinged on its -Z side.
		if has_door:
			var z0 := -door_w * 0.5
			EarthshipBuilder.emit_cyl(ftool, Vector3(x, 0.0, z0), Vector3(x, door_h, z0), r, 6)
			EarthshipBuilder.emit_cyl(ftool, Vector3(x, 0.0, -z0), Vector3(x, door_h, -z0), r, 6)
			EarthshipBuilder.emit_cyl(ftool, Vector3(x, door_h, z0), Vector3(x, door_h, -z0), r, 6)
			_add_door(root, Vector3(x, 0.0, z0), door_w, door_h, door_end)
	_add_tunnel_vents(root, s, fr)
	_add_tunnel_gutters(kit, s, fr)


static func _add_tunnel_vents(root: Node3D, s: Dictionary, fr: Dictionary) -> void:
	var vents := _node(root, "Vents")
	var hl := float(s["length_m"]) * 0.5
	var hw := float(s["width_m"]) * 0.5
	var sink := float(s["ground"]["sink_m"])
	var prof: PackedVector2Array = fr["profile"]
	var gl := GreenhouseMaterials.glazing(str(s["glazing"]["roof"]))
	var gcol := _glazing_color(gl)
	var nodes: Array = []
	for v in fr["vents"]:
		var vd: Dictionary = v
		match str(vd["kind"]):
			"ridge":
				# A flap along the length hinged at the top, opening up and out.
				var form := str(s["form"])
				var hz := float(vd["z"])
				var hy := GreenhouseFrame.height_at(prof, hz) - 0.02
				var w := float(s["vents"]["ridge_w_m"])
				var hinge := _node(vents, "Ridge0")
				hinge.position = Vector3(0.0, hy, hz)
				var slope := 0.35 if form != "lean_to" else 0.0
				var flap := _panel(Vector3(float(s["length_m"]) - 0.2, 0.02, w), gcol)
				flap.position = Vector3(0.0, -w * 0.5 * slope, w * 0.5)
				hinge.add_child(flap)
				hinge.set_meta("vent_kind", "ridge")
				hinge.set_meta("axis", Vector3.RIGHT)
				nodes.append(hinge)
			"sides":
				var n_sides := 1 if str(s["form"]) == "lean_to" else 2
				var h := float(s["vents"]["side_h_m"])
				for k in n_sides:
					var sz := 1.0 if (k == 0 and n_sides == 1) else (-1.0 if k == 0 else 1.0)
					var zw := sz * (_wall_z(prof, sink + h * 0.5, sz) + 0.03)
					var side := _node(vents, "Side%d" % k)
					side.position = Vector3(0.0, sink, zw)
					side.set_meta("vent_kind", "sides")
					side.set_meta("height_m", h)
					side.set_meta("style", str(s["vents"]["sides"]))
					# Curtain hangs from the top; the roll tube climbs as it opens.
					var cur := _node(side, "Curtain")
					cur.position = Vector3(0.0, h, 0.0)
					var cp := _panel(Vector3(float(s["length_m"]) - 0.2, h, 0.01), gcol)
					cp.position = Vector3(0.0, -h * 0.5, 0.0)
					cur.add_child(cp)
					var tube := MeshInstance3D.new()
					tube.name = "Tube"
					var cm := CylinderMesh.new()
					cm.top_radius = 0.025
					cm.bottom_radius = 0.025
					cm.height = float(s["length_m"]) - 0.2
					tube.mesh = cm
					tube.rotation = Vector3(0.0, 0.0, PI * 0.5)
					tube.material_override = StructureMaterials.make(StructureMaterials.Kind.GALVANISED, COLORS["gutter"])
					tube.set_meta("skip_prop_collision", true)
					side.add_child(tube)
					nodes.append(side)
			"ends":
				var eh := float(vd["height_m"])
				var a := float(s["vents"]["end_m2"])
				var side_len := sqrt(a)
				for k in 2:
					var sx := -1.0 if k == 0 else 1.0
					var lv := _node(vents, "End%d" % k)
					lv.position = Vector3(sx * (hl + 0.04), eh, hw * 0.35)
					lv.set_meta("vent_kind", "ends")
					lv.set_meta("axis", Vector3.BACK)
					_louvre(lv, side_len, sx)
					nodes.append(lv)
	root.set_meta("vent_nodes", nodes.size())


## Where the wall is (|z|) at height y on the profile's side `sz`.
static func _wall_z(prof: PackedVector2Array, y: float, sz: float) -> float:
	var best := 0.0
	for i in prof.size() - 1:
		var a := prof[i]
		var b := prof[i + 1]
		if signf(a.x + b.x) != sz and absf(a.x + b.x) > 1e-4:
			continue
		var lo := minf(a.y, b.y)
		var hi := maxf(a.y, b.y)
		if y < lo or y > hi or hi - lo < 1e-6:
			continue
		var t := (y - a.y) / (b.y - a.y)
		best = maxf(best, absf(lerpf(a.x, b.x, t)))
	return best


static func _add_tunnel_gutters(kit: Dictionary, s: Dictionary, fr: Dictionary) -> void:
	if not bool(s["rain"]["gutters"]):
		return
	var hl := float(s["length_m"]) * 0.5
	var prof: PackedVector2Array = fr["profile"]
	var form := str(s["form"])
	var sink := float(s["ground"]["sink_m"])
	var gy := maxf(float(s["eave_h_m"]), 0.35)
	if form == "lean_to":
		gy = float(s["front_h_m"])
	var sides: Array = [1.0] if form == "lean_to" else [-1.0, 1.0]
	var gt := _tool(kit, "gutter")
	for sz: float in sides:
		var z := sz * (_wall_z(prof, gy, sz) + 0.09)
		EarthshipBuilder.emit_box(gt, Vector3(-hl, gy - 0.06, z - 0.06), Vector3(hl, gy, z + 0.06))
		# The downpipe at the +X end.
		EarthshipBuilder.emit_cyl(gt, Vector3(hl - 0.1, gy, z), Vector3(hl - 0.1, sink * 0.0 + 0.2, z), 0.035, 6)
	var cl := float(s["rain"]["cistern_l"])
	if cl > 0.0:
		var h := clampf(pow(cl / 1000.0, 1.0 / 3.0) * 1.1, 0.9, 3.0)
		var rad := sqrt(cl / 1000.0 / (PI * h))
		var c := Vector3(hl + rad + 0.4, sink, float(s["width_m"]) * 0.5 - rad)
		EarthshipBuilder.emit_cyl(_tool(kit, "cistern"), c, c + Vector3(0.0, h, 0.0), rad, 16)


# --- dome ---------------------------------------------------------------------

static func _build_dome(root: Node3D, d: Dictionary, kit: Dictionary, cutaway: bool) -> void:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	var ds: Dictionary = fr["dome"]["spec"]
	var dome := DomeLabBuilder.build_node(ds, "Dome")
	if cutaway:
		var gz := dome.get_node_or_null("Glazing")
		if gz != null:
			(gz as Node3D).visible = false
	for mi in dome.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).set_meta("skip_prop_collision", true)
	root.add_child(dome)
	# Collision: every panel but the ones round the door.
	var door: Dictionary = (fr["doors"] as Array)[0]
	var dw := float(door["w_m"])
	var dh := float(door["h_m"])
	for f in fr["faces"]:
		var fd: Dictionary = f
		var c: Vector3 = fd["centre"]
		if c.z > 0.0 and absf(c.x) < dw and c.y < dh + 0.4:
			continue
		var poly: PackedVector3Array = fd["poly"]
		for k in range(1, poly.size() - 1):
			EarthshipBuilder._tri(kit["col"], poly[0], poly[k], poly[k + 1], fd["normal"])
	# Door frame and door at +Z on the floor ring.
	var z := float(door["z"])
	var ftool := _tool(kit, "frame")
	var r := 0.018
	EarthshipBuilder.emit_cyl(ftool, Vector3(-dw * 0.5, 0.0, z), Vector3(-dw * 0.5, dh, z), r, 6)
	EarthshipBuilder.emit_cyl(ftool, Vector3(dw * 0.5, 0.0, z), Vector3(dw * 0.5, dh, z), r, 6)
	EarthshipBuilder.emit_cyl(ftool, Vector3(-dw * 0.5, dh, z), Vector3(dw * 0.5, dh, z), r, 6)
	_add_door(root, Vector3(-dw * 0.5, 0.0, z + 0.02), dw, dh, 0.0)
	# Vents: hatches round the top, louvres round the base.
	var vents := _node(root, "Vents")
	var height := float(fr["dome"]["height_m"])
	var R := float(fr["dome"]["radius_m"])
	var gcol := _glazing_color(GreenhouseMaterials.glazing(str(s["glazing"]["roof"])))
	for v in fr["vents"]:
		var vd: Dictionary = v
		var n := 6 if str(vd["kind"]) == "ridge" else 8
		for i in n:
			var a := TAU * (float(i) + 0.5) / float(n)
			var y := float(vd["height_m"])
			var rr := sqrt(maxf(R * R - pow(y - (height - R), 2.0), 0.04))
			var hinge := _node(vents, "%s%d" % [str(vd["kind"]).capitalize(), i])
			hinge.position = Vector3(cos(a) * rr, y, sin(a) * rr)
			hinge.rotation = Vector3(0.0, -a + PI * 0.5, 0.0)
			var sz := sqrt(float(vd["area_m2"]) / float(n))
			var flap := _panel(Vector3(sz, 0.02, sz * 0.8), gcol)
			flap.position = Vector3(0.0, 0.0, -sz * 0.4)
			hinge.add_child(flap)
			hinge.set_meta("vent_kind", str(vd["kind"]))
			hinge.set_meta("axis", Vector3.RIGHT)
	var cl := float(s["rain"]["cistern_l"])
	if cl > 0.0:
		var h := clampf(pow(cl / 1000.0, 1.0 / 3.0) * 1.1, 0.9, 3.0)
		var rad := sqrt(cl / 1000.0 / (PI * h))
		var c2 := Vector3(R * 0.75, float(s["ground"]["sink_m"]), R * 0.75 + rad)
		EarthshipBuilder.emit_cyl(_tool(kit, "cistern"), c2, c2 + Vector3(0.0, h, 0.0), rad, 16)


# --- shared extras ------------------------------------------------------------

static func _build_common(root: Node3D, d: Dictionary, kit: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var fr: Dictionary = d["frame"]
	# Floor: a thin gravel slab over the footprint (walked on).
	var flt := _tool(kit, "floor")
	if str(fr["floor"]["kind"]) == "circle":
		var r := float(fr["floor"]["r"])
		var ring := PackedVector2Array()
		for i in 32:
			var a := TAU * float(i) / 32.0
			ring.append(Vector2(cos(a) * r, sin(a) * r))
		_emit_floor(flt, ring)
		_emit_floor(kit["col"], ring)
	else:
		var hl := float(s["length_m"]) * 0.5
		var hw := float(s["width_m"]) * 0.5
		var rect := PackedVector2Array([Vector2(-hl, -hw), Vector2(hl, -hw), Vector2(hl, hw), Vector2(-hl, hw)])
		_emit_floor(flt, rect)
		_emit_floor(kit["col"], rect)
	# Barrels.
	var bc := "barrel_blue" if str(s["mass"]["colour"]) == "blue" else "barrel_black"
	var bt := _tool(kit, bc)
	var bh := clampf(float(s["mass"]["litres_each"]) / 208.0 * 0.88, 0.4, 1.6)
	for p in d["barrels"]["positions"]:
		var pv: Vector2 = p
		EarthshipBuilder.emit_cyl(bt, Vector3(pv.x, 0.0, pv.y), Vector3(pv.x, bh, pv.y), GreenhouseBeds.BARREL_D * 0.5, 14)
	# Fans in the back (-X) end wall (a dome: the back, -Z), blades to spin.
	var nf := int(s["fans"]["count"])
	if nf > 0:
		var fans := _node(root, "Fans")
		var fan := GreenhouseMaterials.fan(str(s["fans"]["kind"]))
		var dm := float(fan["d_m"])
		for i in nf:
			var fnode := _node(fans, "F%d" % i)
			if str(fr["form"]) == "dome":
				var a := -PI * 0.5 + (float(i) - float(nf - 1) * 0.5) * 0.5
				var rr := float(fr["floor"]["r"]) - 0.25
				fnode.position = Vector3(cos(a) * rr, 1.4, sin(a) * rr)
				fnode.rotation = Vector3(0.0, -a, 0.0)
			else:
				var hw2 := float(s["width_m"]) * 0.5
				var zf := (float(i) - float(nf - 1) * 0.5) * (dm + 0.25)
				zf = clampf(zf, -hw2 + dm, hw2 - dm)
				var yf := clampf(GreenhouseFrame.height_at(fr["profile"], zf) * 0.55, dm * 0.6 + 0.3, 3.0)
				fnode.position = Vector3(-float(s["length_m"]) * 0.5 - 0.15, yf, zf)
			var housing := _panel(Vector3(0.3, dm + 0.12, dm + 0.12), COLORS["fan"])
			fnode.add_child(housing)
			var blades := _node(fnode, "Blades")
			blades.position = Vector3(-0.18, 0.0, 0.0)
			for k in 3:
				var bl := _panel(Vector3(0.02, dm * 0.42, 0.12), COLORS["fan"].darkened(0.3))
				bl.position = Vector3(0.0, dm * 0.21, 0.0)
				var arm := Node3D.new()
				arm.rotation = Vector3(TAU * float(k) / 3.0, 0.0, 0.0)
				arm.add_child(bl)
				blades.add_child(arm)
		root.set_meta("fan_nodes", nf)
	# Heater and the controller box by the main door.
	var door: Dictionary = (fr["doors"] as Array)[0]
	var dn: Vector3 = door["normal"]
	var inside := Vector3(float(door["x"]), 0.0, float(door["z"])) - dn * 0.35
	var side := dn.cross(Vector3.UP).normalized()
	var ctl := inside + side * (float(door["w_m"]) * 0.5 + 0.35) + Vector3(0.0, 1.3, 0.0)
	EarthshipBuilder.emit_box(_tool(kit, "controller"), ctl - Vector3(0.12, 0.15, 0.12), ctl + Vector3(0.12, 0.15, 0.12))
	if float(GreenhouseMaterials.heater(str(s["heater"]))["w"]) > 0.0:
		var hp := inside - side * (float(door["w_m"]) * 0.5 + 0.5) + Vector3(0.0, 0.0, 0.0)
		EarthshipBuilder.emit_box(_tool(kit, "heater"), hp - Vector3(0.25, 0.0, 0.25), hp + Vector3(0.25, 0.7, 0.25))


static func _add_door(root: Node3D, hinge_pos: Vector3, w: float, h: float, end_sign: float) -> void:
	var doors := _node(root, "Doors")
	var dnode := _node(doors, "D%d" % doors.get_child_count())
	dnode.position = hinge_pos
	var leaf := _panel(Vector3(0.04, h - 0.02, w - 0.04), COLORS["door"])
	if end_sign == 0.0:
		leaf = _panel(Vector3(w - 0.04, h - 0.02, 0.04), COLORS["door"])
		leaf.position = Vector3(w * 0.5, h * 0.5, 0.0)
	else:
		leaf.position = Vector3(0.0, h * 0.5, w * 0.5)
	dnode.add_child(leaf)
	dnode.set_meta("end", end_sign)


## Louvre slats in an end wall (they turn about Z as they open).
static func _louvre(parent: Node3D, side_len: float, sx: float) -> void:
	var n := maxi(int(side_len / 0.12), 3)
	for i in n:
		var slat := Node3D.new()
		slat.name = "Slat%d" % i
		slat.position = Vector3(0.0, -side_len * 0.5 + side_len * (float(i) + 0.5) / float(n), 0.0)
		var p := _panel(Vector3(0.01, side_len / float(n) * 0.95, side_len), COLORS["fan"])
		slat.add_child(p)
		parent.add_child(slat)


# --- the runtime's knobs ------------------------------------------------------

## Open every vent to `frac` (0 shut .. 1 wide open); `by_kind` overrides it
## per kind ({"ridge": 0.4, ...}).
static func set_vents(model: Node, frac: float, by_kind: Dictionary = {}) -> void:
	var vents := _find(model, "Vents")
	if vents == null:
		return
	for v in vents.get_children():
		var vn := v as Node3D
		var kind := str(vn.get_meta("vent_kind", ""))
		var f := clampf(float(by_kind.get(kind, frac)), 0.0, 1.0)
		match kind:
			"sides":
				var h := float(vn.get_meta("height_m", 1.0))
				var cur := vn.get_node_or_null("Curtain") as Node3D
				var tube := vn.get_node_or_null("Tube") as Node3D
				if cur != null:
					cur.scale = Vector3(1.0, maxf(1.0 - f, 0.02), 1.0)
				if tube != null:
					tube.position = Vector3(0.0, f * h, 0.0)
			"ends":
				for slat in vn.get_children():
					(slat as Node3D).rotation = Vector3(0.0, 0.0, f * deg_to_rad(75.0))
			_:
				var ax: Vector3 = vn.get_meta("axis", Vector3.RIGHT)
				if not vn.has_meta("rest_basis"):
					vn.set_meta("rest_basis", vn.basis)
				vn.basis = (vn.get_meta("rest_basis") as Basis) * Basis(ax, -f * deg_to_rad(VENT_MAX_DEG))


## Doors open (0..1): they swing out about their hinge.
static func set_doors(model: Node, frac: float) -> void:
	var doors := _find(model, "Doors")
	if doors == null:
		return
	for dn in doors.get_children():
		var end := float((dn as Node3D).get_meta("end", 0.0))
		var ang := clampf(frac, 0.0, 1.0) * deg_to_rad(100.0)
		(dn as Node3D).rotation = Vector3(0.0, -ang * (end if end != 0.0 else 1.0), 0.0)


## Turn every fan's blades by `delta_rad`.
static func spin_fans(model: Node, delta_rad: float) -> void:
	var fans := _find(model, "Fans")
	if fans == null:
		return
	for f in fans.get_children():
		var b := (f as Node).get_node_or_null("Blades") as Node3D
		if b != null:
			b.rotation.x = fposmod(b.rotation.x + delta_rad, TAU)


static func _find(model: Node, name: String) -> Node:
	if model == null:
		return null
	var n := model.get_node_or_null(name)
	if n != null:
		return n
	return model.find_child(name, true, false)


# --- emitters + kit -----------------------------------------------------------

static func _st() -> SurfaceTool:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	return t


static func _tool(kit: Dictionary, mat: String) -> SurfaceTool:
	var tools: Dictionary = kit["tools"]
	if not tools.has(mat):
		tools[mat] = _st()
	return tools[mat]


static func _glaze(kit: Dictionary, gid: String) -> SurfaceTool:
	var g: Dictionary = kit["glaze"]
	if not g.has(gid):
		g[gid] = _st()
	return g[gid]


static func _node(parent: Node, name: String) -> Node3D:
	var n := parent.get_node_or_null(name) as Node3D
	if n == null:
		n = Node3D.new()
		n.name = name
		parent.add_child(n)
	return n


static func _panel(size: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	if col.a < 0.99:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.roughness = 0.4
	mi.material_override = m
	mi.set_meta("skip_prop_collision", true)
	return mi


## A (z, y) polygon on the plane x, facing +X when `sgn` > 0.
static func _emit_poly_x(st: SurfaceTool, poly: PackedVector2Array, x: float, sgn: float) -> void:
	if poly.size() < 3:
		return
	var idx := Geometry2D.triangulate_polygon(poly)
	var n := Vector3(signf(sgn) if sgn != 0.0 else 1.0, 0.0, 0.0)
	for k in range(0, idx.size(), 3):
		var a := poly[idx[k]]
		var b := poly[idx[k + 1]]
		var c := poly[idx[k + 2]]
		EarthshipBuilder._tri(st, Vector3(x, a.y, a.x), Vector3(x, b.y, b.x), Vector3(x, c.y, c.x), n)


static func _emit_floor(st: SurfaceTool, ring: PackedVector2Array) -> void:
	var idx := Geometry2D.triangulate_polygon(ring)
	for k in range(0, idx.size(), 3):
		var a := ring[idx[k]]
		var b := ring[idx[k + 1]]
		var c := ring[idx[k + 2]]
		EarthshipBuilder._tri(st, Vector3(a.x, 0.01, a.y), Vector3(b.x, 0.01, b.y), Vector3(c.x, 0.01, c.y), Vector3.UP)


## A (z, y) polygon cut at height `cut`: [[poly, below]] pieces.
static func _split_poly_at(poly: PackedVector2Array, cut: float) -> Array:
	if cut <= 0.0:
		return [[poly, false]]
	var big := 1000.0
	var below := PackedVector2Array([Vector2(-big, -big), Vector2(big, -big), Vector2(big, cut), Vector2(-big, cut)])
	var out: Array = []
	for p in Geometry2D.intersect_polygons(poly, below):
		out.append([p, true])
	for p2 in Geometry2D.clip_polygons(poly, below):
		out.append([p2, false])
	return out


static func _glazing_color(g: Dictionary) -> Color:
	var tau := float(g.get("tau", 0.8))
	# Film reads milky, twin-wall a little frosted, glass nearly clear.
	var a := 0.1 + (1.0 - tau) * 0.9
	if str(g.get("look", "")) == "tarp_pe":
		return Color(0.92, 0.95, 0.96, a + 0.08)
	if str(g.get("look", "")).begins_with("polycarb"):
		return Color(0.84, 0.92, 0.98, a + 0.05)
	return Color(0.80, 0.90, 0.92, a)


static func _commit(root: Node3D, s: Dictionary, kit: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	var tools: Dictionary = kit["tools"]
	var keys: Array = tools.keys()
	keys.sort()
	for k in keys:
		var before := mesh.get_surface_count()
		(tools[k] as SurfaceTool).commit(mesh)
		if mesh.get_surface_count() > before:
			mesh.surface_set_material(mesh.get_surface_count() - 1, _material(str(k), s))
	if mesh.get_surface_count() > 0:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = mesh
		mi.set_meta("skip_prop_collision", true)
		root.add_child(mi)
	var gm := ArrayMesh.new()
	var gk: Array = (kit["glaze"] as Dictionary).keys()
	gk.sort()
	for k2 in gk:
		var before2 := gm.get_surface_count()
		(kit["glaze"][k2] as SurfaceTool).commit(gm)
		if gm.get_surface_count() > before2:
			gm.surface_set_material(gm.get_surface_count() - 1, glazing_material(str(k2)))
	if gm.get_surface_count() > 0:
		var gi := MeshInstance3D.new()
		gi.name = "Glazing"
		gi.mesh = gm
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gi.set_meta("skip_prop_collision", true)
		root.add_child(gi)
	if int(kit["shade_n"]) > 0:
		var sm := (kit["shade"] as SurfaceTool).commit()
		var shm := StandardMaterial3D.new()
		shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		shm.cull_mode = BaseMaterial3D.CULL_DISABLED
		shm.albedo_color = Color(COLORS["shade"].r, COLORS["shade"].g, COLORS["shade"].b, float(s["shade"]["cloth"]))
		sm.surface_set_material(0, shm)
		var si := MeshInstance3D.new()
		si.name = "Shade"
		si.mesh = sm
		si.set_meta("skip_prop_collision", true)
		root.add_child(si)
	var cm := MeshInstance3D.new()
	cm.name = "CollisionMesh"
	cm.mesh = (kit["col"] as SurfaceTool).commit()
	cm.visible = false
	root.add_child(cm)


static func glazing_material(gid: String) -> Material:
	var g := GreenhouseMaterials.glazing(gid)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = _glazing_color(g)
	m.roughness = 0.08 if str(g["look"]).begins_with("pmma") else 0.35
	m.metallic_specular = 0.7
	return m


static func _material(mat: String, s: Dictionary) -> Material:
	if mat == "frame":
		var fm := GreenhouseMaterials.frame(str(s["frame"]))
		match str(fm["look"]):
			"wood":
				return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.62, 0.48, 0.32))
			"alu":
				return StructureMaterials.make(StructureMaterials.Kind.ALUMINIUM, s["colors"]["frame"])
		return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, s["colors"]["frame"])
	if mat.begins_with("wall_"):
		var w := GreenhouseMaterials.wall(mat.substr(5))
		if mat.contains("stud"):
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, w["color"])
		var wm := StandardMaterial3D.new()
		wm.albedo_color = w["color"]
		wm.roughness = 0.92
		return wm
	match mat:
		"gutter":
			return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, COLORS["gutter"])
		"barrel_black", "barrel_blue", "cistern":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, COLORS[mat])
		"controller":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, COLORS[mat])
		"heater":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, COLORS[mat])
	var m := StandardMaterial3D.new()
	m.albedo_color = COLORS.get(mat, Color(0.6, 0.6, 0.6))
	m.roughness = 0.95
	return m

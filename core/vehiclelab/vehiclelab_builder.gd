class_name VehicleBuilder
extends RefCounted

## Draws a solved living vehicle (VehicleDesign) in metres. Frame: the origin
## on the ground under the middle of its length, -Z = its front, +X = its
## right (curb) side — the rider's forward, so PlacedVehicle's yaw_deg is 0.
##
## Node tree:
##   LivingVehicle (Node3D)   metas: seat_spots, role_spots, living_vehicle,
##                            vehicle_key (see below)
##     Mesh   chassis, wheels, cab, floor and the interior
##     Shell  the living box's skin: walls, roof, windows, doors, stripes —
##            its own node so a cutaway view hides it and shows the inside
##
## seat_spots (FlatpackBuilder's meta, read by NpcPopulationBridge
## .furniture_spots): the beds as {pos (mattress top), yaw, kind "lie",
## length_m} first, then the seats {kind "sit"}. role_spots: {kitchen,
## shower, restroom: [{pos (on the floor), yaw, kind "stand"}]} — where a
## person stands to cook / wash, raised to the vehicle's floor.
##
## Every triangle goes through _K.tri, which puts its corners in Godot's
## front-face order (clockwise seen from outside) whatever order it is given,
## and every normal is written by hand (never generate_normals(): its smooth
## groups round flat panels into a bubble — the dome lesson).

const MODEL_ID := "vehiclelab_vehicle"
## Catalog ids that build a living vehicle: the designer's own and one per
## built-in preset ("vehiclelab_<preset id>").
const ID_PREFIX := "vehiclelab_"

const C_TRIM := Color(0.11, 0.11, 0.12)
const C_TYRE := Color(0.06, 0.06, 0.065)
const C_GLASS := Color(0.08, 0.11, 0.14)
const C_HEAD := Color(0.95, 0.93, 0.82)
const C_TAIL := Color(0.7, 0.05, 0.04)
const C_FRAME := Color(0.08, 0.08, 0.09)
const C_FLOOR := Color(0.52, 0.42, 0.3)
const C_FABRIC := Color(0.78, 0.76, 0.7)
const C_PILLOW := Color(0.93, 0.92, 0.88)


static func handles(model_id: String) -> bool:
	return model_id.begins_with(ID_PREFIX)


## The spec a catalog id builds when the record carries none: the preset the
## id names, else the van.
static func preset_for_model(model_id: String) -> Dictionary:
	var pid := model_id.substr(ID_PREFIX.length()) if handles(model_id) else "van"
	if pid == "vehicle":
		pid = "van"
	return VehiclePresets.builtin(pid)


static func spec_for_record(rec: Dictionary) -> Dictionary:
	var s: Variant = rec.get("vehicle_spec", {})
	if s is Dictionary and not (s as Dictionary).is_empty():
		return s
	return preset_for_model(str(rec.get("model_id", MODEL_ID)))


static func build_node(spec: Dictionary, model_id: String = MODEL_ID, opts: Dictionary = {}) -> Node3D:
	var sp := spec if not spec.is_empty() else preset_for_model(model_id)
	var d := VehicleDesign.solve(sp)
	return build_from_design(d, opts)


static func build_from_design(d: Dictionary, opts: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = "LivingVehicle"
	var paint: Dictionary = (d["spec"] as Dictionary)["paint"]
	var body_c := VehicleSpec.color(paint["body"])
	var roof_c := VehicleSpec.color(paint["roof"])
	var trim_c := VehicleSpec.color(paint["trim"])
	var g := {
		"body": _K.new(), "roof": _K.new(), "trim": _K.new(), "glass": _K.new(),
		"tyre": _K.new(), "rim": _K.new(), "head": _K.new(), "tail": _K.new(),
		"frame": _K.new(), "stripe": _K.new(),
		"floor": _K.new(), "wood": _K.new(), "fabric": _K.new(), "white": _K.new(),
		"dark": _K.new(), "pillow": _K.new(), "lamp": _K.new(), "mirror": _K.new(),
	}
	var shell := {"body": _K.new(), "roof": _K.new(), "glass": _K.new(), "trim": _K.new(),
		"stripe": _K.new(), "door": _K.new()}
	_chassis(d, g)
	_wheels(d, g)
	_cab(d, g)
	_body(d, shell, g)
	_floor_and_interior(d, g)
	var mesh := ArrayMesh.new()
	_commit(g["body"], mesh, StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, body_c))
	_commit(g["roof"], mesh, StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, roof_c))
	_commit(g["trim"], mesh, _plain(trim_c, 0.1, 0.7))
	_commit(g["glass"], mesh, _plain(C_GLASS, 0.3, 0.08))
	_commit(g["tyre"], mesh, _plain(C_TYRE, 0.0, 0.9))
	_commit(g["rim"], mesh, _plain(VehicleSpec.color(paint["wheels"]), 0.7, 0.35))
	_commit(g["head"], mesh, _emissive(C_HEAD, 0.6))
	_commit(g["tail"], mesh, _emissive(C_TAIL, 0.4))
	_commit(g["frame"], mesh, _plain(C_FRAME, 0.3, 0.6))
	_commit(g["stripe"], mesh, _plain(VehicleSpec.color(paint["stripe"]), 0.1, 0.5))
	_commit(g["floor"], mesh, StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, C_FLOOR))
	_commit(g["wood"], mesh, StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.62, 0.49, 0.33)))
	_commit(g["fabric"], mesh, StructureMaterials.make(StructureMaterials.Kind.FABRIC, C_FABRIC))
	_commit(g["white"], mesh, _plain(Color(0.9, 0.91, 0.92), 0.0, 0.4))
	_commit(g["dark"], mesh, _plain(Color(0.14, 0.15, 0.17), 0.2, 0.5))
	_commit(g["pillow"], mesh, StructureMaterials.make(StructureMaterials.Kind.FABRIC, C_PILLOW))
	_commit(g["lamp"], mesh, _emissive(Color(1.0, 0.95, 0.82), 1.2))
	_commit(g["mirror"], mesh, _plain(Color(0.7, 0.75, 0.8), 0.9, 0.05))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	root.add_child(mi)
	if not bool(opts.get("cutaway", false)):
		var smesh := ArrayMesh.new()
		_commit(shell["body"], smesh, StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, body_c))
		_commit(shell["roof"], smesh, StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, roof_c))
		_commit(shell["glass"], smesh, _plain(C_GLASS, 0.3, 0.08))
		_commit(shell["trim"], smesh, _plain(trim_c, 0.1, 0.7))
		_commit(shell["stripe"], smesh, _plain(VehicleSpec.color(paint["stripe"]), 0.1, 0.5))
		_commit(shell["door"], smesh, StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL,
			body_c.darkened(0.12)))
		var smi := MeshInstance3D.new()
		smi.name = "Shell"
		smi.mesh = smesh
		root.add_child(smi)
	root.set_meta("living_vehicle", true)
	root.set_meta("vehicle_key", VehicleSpec.key_of(d["spec"]))
	var spots: Array = []
	for b in d["beds"]:
		var bd: Dictionary = b
		spots.append({"pos": bd["pos"], "yaw": float(bd["yaw"]), "kind": "lie",
			"length_m": float(bd["length_m"])})
	spots.append_array(d["seat_spots"])
	root.set_meta("seat_spots", spots)
	root.set_meta("role_spots", d["role_spots"])
	return root


# --- chassis + wheels ----------------------------------------------------------------

static func _chassis(d: Dictionary, g: Dictionary) -> void:
	var fr: Dictionary = d["frame"]
	var fy := float(fr["y"])
	var half := float(d["half_len"])
	var axles: Array = d["axles"]
	if axles.is_empty():
		return
	var z_a := float((axles[0] as Dictionary)["zf"]) - half - 0.6
	var z_b := float((axles[axles.size() - 1] as Dictionary)["zf"]) - half + 0.8
	var cab := str(d["cab"])
	if cab == "none":
		z_a = -half
	z_b = minf(z_b, half - 0.2)
	var fk: _K = g["frame"]
	for sx in [-1.0, 1.0]:
		fk.box(Vector3(sx * 0.45, fy - 0.12, (z_a + z_b) * 0.5), Vector3(0.09, 0.22, z_b - z_a))
	# Axles.
	for a in axles:
		var z := float((a as Dictionary)["zf"]) - half
		var wr: float = float((d["wheels"] as Array)[0]["r"]) if not (d["wheels"] as Array).is_empty() else 0.4
		fk.cylinder(Vector3(0, wr, z), 0.07, float(fr["track"]) * 0.95, Vector3.RIGHT, 10)
	# A fuel tank on the frame's left (not on a trailer or an EV).
	if cab != "none" and str(d["fuel"]) != "electric":
		var wb_mid := (float((axles[0] as Dictionary)["zf"]) + float((axles[mini(1, axles.size() - 1)] as Dictionary)["zf"])) * 0.5 - half
		fk.cylinder(Vector3(-0.7, fy - 0.3, wb_mid), 0.25, 0.9, Vector3.BACK, 14)
	if cab == "none":
		# The A-frame tongue and its coupler.
		var bz0 := float((d["body"] as Dictionary)["z0"])
		var tip := Vector3(0, fy, -half + 0.05)
		for sx in [-1.0, 1.0]:
			var base := Vector3(sx * 0.55, fy, bz0 + 0.1)
			var mid := (base + tip) * 0.5
			var along := (base - tip)
			var ax := along * 0.5
			var ay := Vector3(0, 0.07, 0)
			var az := Vector3.UP.cross(along).normalized() * 0.05
			fk.obox(mid, ax, ay, az)
		fk.box(tip + Vector3(0, 0.05, 0.05), Vector3(0.16, 0.12, 0.25))
		fk.cylinder(Vector3(0, fy * 0.5, -half + 0.45), 0.04, fy, Vector3.UP, 8)
		# A travel trailer's propane bottles on the tongue.
		if str((d["body"] as Dictionary)["id"]) == "travel_trailer":
			var wk: _K = g["white"]
			for sx2 in [-0.2, 0.2]:
				wk.cylinder(Vector3(sx2, fy + 0.35, bz0 - 0.45), 0.16, 0.6, Vector3.UP, 14)


static func _wheels(d: Dictionary, g: Dictionary) -> void:
	var hw := float((d["body"] as Dictionary)["w"]) * 0.5
	var cab_w := float((d["cab_geo"] as Dictionary)["w"]) * 0.5
	var lim := maxf(hw, cab_w)
	var tk: _K = g["tyre"]
	var rk: _K = g["rim"]
	for w in d["wheels"]:
		var wd: Dictionary = w
		var p: Vector3 = wd["pos"]
		var r := float(wd["r"])
		var tw := float(wd["w"])
		# Never stick out past the body.
		var side := 1.0 if p.x >= 0.0 else -1.0
		if absf(p.x) + tw * 0.5 > lim - 0.005:
			p.x -= side * (absf(p.x) + tw * 0.5 - (lim - 0.005))
		tk.cylinder(p, r, tw, Vector3.RIGHT, 22)
		rk.cylinder(p + Vector3(side * 0.006, 0, 0), r * 0.58, tw, Vector3.RIGHT, 16)
		rk.cylinder(p + Vector3(side * (tw * 0.5 + 0.01), 0, 0), r * 0.18, 0.04, Vector3.RIGHT, 10)


# --- cab ------------------------------------------------------------------------------

## The front of the vehicle per cab style, as a side profile (z, y) extruded
## across its width, plus its windshield, lights, bumper and mirrors.
static func _cab(d: Dictionary, g: Dictionary) -> void:
	var cg: Dictionary = d["cab_geo"]
	var style := str(cg["style"])
	if style == "none":
		return
	var z0 := float(cg["z0"])
	var hood := float(cg["hood"])
	var cab_len := float(cg["cab_len"])
	var cab_h := float(cg["h"])
	var cab_w := float(cg["w"])
	var fy := float(cg["frame_h"])
	var yb := maxf(fy - 0.32, 0.28)
	var b: Dictionary = d["body"]
	var bk: _K = g["body"]
	var gk: _K = g["glass"]
	var integral := bool(cg["integral"])
	var hood_top := fy + 0.55
	match style:
		"full_van", "cutaway":
			var prof := PackedVector2Array([
				Vector2(z0, yb), Vector2(z0, yb + 0.5), Vector2(z0 + 0.22, hood_top),
				Vector2(z0 + hood, hood_top + 0.1), Vector2(z0 + hood + 0.85, cab_h),
				Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
			_extrude_side(bk, prof, cab_w)
			_glass_slope(gk, Vector2(z0 + hood + 0.05, hood_top + 0.14),
				Vector2(z0 + hood + 0.8, cab_h - 0.05), cab_w * 0.9)
			_side_windows(gk, z0 + hood + 0.25, z0 + hood + 1.05, hood_top + 0.25, cab_h - 0.12, cab_w)
		"cowl":
			hood_top = fy + 0.75
			var hp := PackedVector2Array([Vector2(z0, yb), Vector2(z0, yb + 0.7),
				Vector2(z0 + 0.12, hood_top), Vector2(z0 + hood, hood_top + 0.05), Vector2(z0 + hood, yb)])
			_extrude_side(bk, hp, cab_w * 0.82)
			# Grille.
			(g["trim"] as _K).box(Vector3(0, (yb + hood_top) * 0.5 + 0.05, z0 - 0.004),
				Vector3(cab_w * 0.6, (hood_top - yb) * 0.6, 0.02))
			if not integral:
				var cp := PackedVector2Array([Vector2(z0 + hood, yb), Vector2(z0 + hood, hood_top + 0.05),
					Vector2(z0 + hood + 0.2, cab_h), Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
				_extrude_side(bk, cp, cab_w)
				_glass_slope(gk, Vector2(z0 + hood + 0.02, hood_top + 0.12),
					Vector2(z0 + hood + 0.18, cab_h - 0.08), cab_w * 0.9)
				_side_windows(gk, z0 + hood + 0.3, z0 + cab_len - 0.3, hood_top + 0.2, cab_h - 0.12, cab_w)
		"forward":
			if not integral:
				var fp := PackedVector2Array([Vector2(z0, yb), Vector2(z0, cab_h - 0.12),
					Vector2(z0 + 0.12, cab_h), Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
				_extrude_side(bk, fp, cab_w)
				_glass_slope(gk, Vector2(z0 - 0.003, fy + 0.75), Vector2(z0 - 0.003, cab_h - 0.2), cab_w * 0.9)
				_side_windows(gk, z0 + 0.2, z0 + cab_len - 0.35, fy + 0.85, cab_h - 0.15, cab_w)
		"tractor":
			hood_top = fy + 0.9
			var tp := PackedVector2Array([Vector2(z0, yb), Vector2(z0, yb + 0.85),
				Vector2(z0 + 0.25, hood_top), Vector2(z0 + hood, hood_top + 0.08), Vector2(z0 + hood, yb)])
			_extrude_side(bk, tp, cab_w * 0.85)
			var cp2 := PackedVector2Array([Vector2(z0 + hood, yb), Vector2(z0 + hood, hood_top + 0.08),
				Vector2(z0 + hood + 0.3, cab_h), Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
			_extrude_side(bk, cp2, cab_w)
			_glass_slope(gk, Vector2(z0 + hood + 0.03, hood_top + 0.15),
				Vector2(z0 + hood + 0.27, cab_h - 0.1), cab_w * 0.9)
			_side_windows(gk, z0 + hood + 0.35, z0 + cab_len - 0.4, hood_top + 0.25, cab_h - 0.15, cab_w)
			(g["trim"] as _K).box(Vector3(0, (yb + hood_top) * 0.5, z0 - 0.004),
				Vector3(cab_w * 0.55, (hood_top - yb) * 0.75, 0.02))
			# Exhaust stacks and the fifth wheel.
			var tr: _K = g["rim"]
			for sx in [-1.0, 1.0]:
				tr.cylinder(Vector3(sx * (cab_w * 0.5 - 0.12), cab_h + 0.5, z0 + cab_len + 0.08),
					0.07, 1.6, Vector3.UP, 10)
	# Bumper, headlights, mirrors (all styles but a trailer).
	var tk: _K = g["trim"]
	var bw := maxf(cab_w, float(b["w"]) if integral else cab_w)
	tk.box(Vector3(0, yb + 0.12, z0 - 0.06), Vector3(bw * 0.98, 0.22, 0.14))
	var hk: _K = g["head"]
	var hl_y := yb + 0.42 if style != "forward" else fy + 0.45
	for sx in [-1.0, 1.0]:
		hk.box(Vector3(sx * (bw * 0.5 - 0.2), hl_y, z0 - 0.006), Vector3(0.24, 0.13, 0.03))
		var mz := z0 + hood + 0.3 if style != "forward" else z0 + 0.25
		var my := maxf(cab_h - 0.6, hood_top + 0.3) if style != "forward" else float(b["h"]) * 0.62
		tk.box(Vector3(sx * (bw * 0.5 + 0.2), my, mz), Vector3(0.05, 0.32, 0.18))
		tk.box(Vector3(sx * (bw * 0.5 + 0.1), my, mz + 0.02), Vector3(0.2, 0.025, 0.03))


# --- the living box ---------------------------------------------------------------------

## The body shell: a rounded cross-section swept along the box, its front
## raked where the vehicle's front is (a van's high roof, a Class A, a step
## van), then windows, doors, stripes, rear lights.
static func _body(d: Dictionary, sh: Dictionary, g: Dictionary) -> void:
	var b: Dictionary = d["body"]
	var cg: Dictionary = d["cab_geo"]
	var style := str(cg["style"])
	var integral := bool(d["integral"])
	var hw := float(b["w"]) * 0.5
	var H := float(b["h"])
	var floor_y := float(b["floor_y"])
	var roof := str(b["roof"])
	var r := clampf(float(b["corner_r"]), 0.0, minf(hw * 0.6, 0.4))
	var crown := 0.0
	match roof:
		"high_top": crown = 0.03
		"crown": crown = 0.1
		"arched": crown = 0.3
		"cabover": crown = 0.07
	var y0 := floor_y - 0.12
	if integral:
		y0 = clampf(floor_y - 0.45, 0.32, 0.6)
	var z0 := float(b["z0"])
	var z1 := float(b["z1"])
	var rake_top := 0.0
	var rake_from := y0
	if style == "full_van":
		# The cab covers the van's front to the windshield top; the shell
		# starts there and its high roof leans back.
		z0 = float(cg["z0"]) + float(cg["hood"]) + 0.8
		rake_from = float(cg["h"])
		rake_top = 0.4
	elif style == "forward" and integral:
		rake_top = 0.45 if str(b["id"]) == "class_a_motorhome" else 0.12
		rake_from = y0 + 0.3
	elif style == "none":
		rake_top = 0.3
		rake_from = (y0 + H) * 0.5
	var prof := _profile(hw, y0, H, r, crown)
	var roof_y := H - crown - r - 0.01
	var bk: _K = sh["body"]
	var rk: _K = sh["roof"]
	var n := prof.size()
	for i in n:
		var a: Vector2 = prof[i]
		var c: Vector2 = prof[(i + 1) % n]
		var f2 := Vector2(c.y - a.y, -(c.x - a.x)).normalized()
		var na := _vnormal(prof, i)
		var nc := _vnormal(prof, (i + 1) % n)
		# A hard corner (the floor's edges) keeps this face's own normal.
		if na.dot(f2) < 0.8:
			na = f2
		if nc.dot(f2) < 0.8:
			nc = f2
		var za := z0 + _rake(a.y, rake_from, H, rake_top)
		var zc := z0 + _rake(c.y, rake_from, H, rake_top)
		var k: _K = rk if a.y >= roof_y and c.y >= roof_y else bk
		var face := Vector3(f2.x, f2.y, 0.0)
		k.quad_n(Vector3(a.x, a.y, za), Vector3(c.x, c.y, zc), Vector3(c.x, c.y, z1), Vector3(a.x, a.y, z1),
			Vector3(na.x, na.y, 0), Vector3(nc.x, nc.y, 0), Vector3(nc.x, nc.y, 0), Vector3(na.x, na.y, 0), face)
	# End caps: a fan from the profile's middle (the profile is convex).
	var mid := Vector2(0.0, (y0 + H) * 0.5)
	var zm := z0 + _rake(mid.y, rake_from, H, rake_top)
	for i in n:
		var a2: Vector2 = prof[i]
		var c2: Vector2 = prof[(i + 1) % n]
		bk.tri(Vector3(mid.x, mid.y, zm), Vector3(a2.x, a2.y, z0 + _rake(a2.y, rake_from, H, rake_top)),
			Vector3(c2.x, c2.y, z0 + _rake(c2.y, rake_from, H, rake_top)), Vector3.FORWARD)
		bk.tri(Vector3(mid.x, mid.y, z1), Vector3(a2.x, a2.y, z1), Vector3(c2.x, c2.y, z1), Vector3.BACK)
	# The Class C's bunk over the cab.
	if roof == "cabover":
		var cz0 := float(cg["z0"]) + float(cg["hood"]) * 0.45
		var cy0 := float(cg["h"]) + 0.03
		var cy1 := H - 0.12
		var cp := PackedVector2Array([Vector2(cz0 + 0.3, cy0), Vector2(cz0, cy0 + 0.25),
			Vector2(cz0 + 0.38, cy1), Vector2(z0 + 0.2, cy1), Vector2(z0 + 0.2, cy0)])
		_extrude_side(bk, cp, hw * 2.0 - 0.06)
	var wall_top := H - crown - r
	_windows(d, sh["glass"], hw, floor_y, wall_top, z0, z1, style, integral, rake_top)
	_doors(d, sh, hw, floor_y, y0, wall_top, z0, z1, style, integral)
	# Integral bodies carry the windshield in their front face.
	if integral and style != "full_van":
		var wz := z0 + _rake(floor_y + 0.9, rake_from, H, rake_top) - 0.006
		var wz2 := z0 + _rake(wall_top - 0.2, rake_from, H, rake_top) - 0.006
		_glass_slope(sh["glass"], Vector2(wz, floor_y + 0.85), Vector2(wz2, wall_top - 0.2), hw * 1.8)
	# Stripe band down both sides.
	var paint: Dictionary = (d["spec"] as Dictionary)["paint"]
	if bool(paint.get("stripe_on", false)):
		var sk: _K = sh["stripe"]
		var sy0 := floor_y + 0.18
		var sy1 := sy0 + 0.16
		for sx in [-1.0, 1.0]:
			var x: float = sx * (hw + 0.004)
			sk.quad(Vector3(x, sy0, z0 + 0.05), Vector3(x, sy0, z1 - 0.05), Vector3(x, sy1, z1 - 0.05),
				Vector3(x, sy1, z0 + 0.05), Vector3(sx, 0, 0))
	# School-bus rub rails.
	if str(b["id"]) == "skoolie":
		var tk: _K = sh["trim"]
		for ry in [floor_y - 0.2, floor_y + 0.55]:
			for sx in [-1.0, 1.0]:
				tk.box(Vector3(sx * (hw + 0.012), ry, (z0 + z1) * 0.5), Vector3(0.02, 0.07, z1 - z0 - 0.1))
	# Rear lights + bumper.
	var tl: _K = g["tail"]
	for sx in [-1.0, 1.0]:
		tl.box(Vector3(sx * (hw - 0.14), y0 + 0.35, z1 + 0.012), Vector3(0.18, 0.28, 0.02))
	(g["trim"] as _K).box(Vector3(0, y0 + 0.02, z1 + 0.07), Vector3(hw * 1.9, 0.16, 0.14))


## The body's cross-section, counter-clockwise from the bottom left: straight
## walls, a rounded corner of radius r, a crown rising to the centre.
static func _profile(hw: float, y0: float, H: float, r: float, crown: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.append(Vector2(-hw, y0))
	pts.append(Vector2(hw, y0))
	var yw := H - crown - r
	var seg := 6
	if r > 0.005:
		for i in seg + 1:
			var a := PI * 0.5 * float(i) / float(seg)
			pts.append(Vector2(hw - r + cos(a) * r, yw + sin(a) * r))
	else:
		pts.append(Vector2(hw, yw))
	var top_hw := hw - r
	var cseg := 6 if crown > 0.005 else 1
	for i in range(1, cseg):
		var t := float(i) / float(cseg)
		var x := top_hw * (1.0 - t)
		pts.append(Vector2(x, H - crown * (x / maxf(top_hw, 0.01)) * (x / maxf(top_hw, 0.01))))
	pts.append(Vector2(0.0, H))
	var right := pts.size()
	# Mirror the right half (without the bottom pair and the apex) onto the left.
	for i in range(right - 2, 1, -1):
		var p := pts[i]
		pts.append(Vector2(-p.x, p.y))
	return pts


## A smooth vertex normal on the profile: the mean of its two edges' outward
## normals, except at the bottom corners (a crisp edge reads as a box).
static func _vnormal(prof: PackedVector2Array, i: int) -> Vector2:
	var n := prof.size()
	var a := prof[(i - 1 + n) % n]
	var p := prof[i]
	var c := prof[(i + 1) % n]
	var e1 := (p - a)
	var e2 := (c - p)
	var n1 := Vector2(e1.y, -e1.x).normalized()
	var n2 := Vector2(e2.y, -e2.x).normalized()
	if n1.dot(n2) < 0.6:
		return n2   # a hard corner: take the following edge's normal
	return (n1 + n2).normalized()


static func _rake(y: float, from_y: float, H: float, top: float) -> float:
	if top <= 0.0 or H <= from_y:
		return 0.0
	return top * clampf((y - from_y) / (H - from_y), 0.0, 1.0)


static func _windows(d: Dictionary, gk: _K, hw: float, floor_y: float, wall_top: float,
		z0: float, z1: float, style: String, integral: bool, rake: float) -> void:
	var kind := str((d["body"] as Dictionary)["windows"])
	if kind == "none":
		return
	var house: Dictionary = d["house"]
	var hz0 := maxf(float(house["z0"]), z0 + rake + 0.25)
	var hz1 := minf(float(house["z1"]), z1) - 0.35
	var y_lo := floor_y + 0.85
	var y_hi := minf(wall_top - 0.18, floor_y + 1.75)
	if y_hi - y_lo < 0.25:
		return
	if kind == "bus" or kind == "band":
		var pane := 0.78 if kind == "bus" else 1.05
		var gap := 0.11
		var z := hz0 if kind == "band" else maxf(z0 + 0.95, hz0 - 0.9)
		while z + pane <= hz1:
			for sx in [-1.0, 1.0]:
				_pane(gk, sx, hw, z, z + pane, y_lo, y_hi)
			z += pane + gap
	else:
		# A few: one each side mid-box, one more on the curb side forward.
		var mz := (hz0 + hz1) * 0.5
		for sx in [-1.0, 1.0]:
			_pane(gk, sx, hw, mz - 0.45, mz + 0.45, y_lo + 0.1, y_hi - 0.05)
		if hz1 - hz0 > 3.0:
			_pane(gk, -1.0, hw, hz1 - 0.9, hz1 - 0.2, y_lo + 0.15, y_hi - 0.1)
	# A rear window on buses / RVs (not on a barn-door van: its doors have them).
	if kind == "bus" or kind == "band":
		gk.quad(Vector3(-hw * 0.7, y_lo + 0.1, z1 + 0.006), Vector3(hw * 0.7, y_lo + 0.1, z1 + 0.006),
			Vector3(hw * 0.7, y_hi, z1 + 0.006), Vector3(-hw * 0.7, y_hi, z1 + 0.006), Vector3.BACK)


static func _pane(gk: _K, sx: float, hw: float, za: float, zb: float, ya: float, yb: float) -> void:
	var x := sx * (hw + 0.004)
	gk.quad(Vector3(x, ya, za), Vector3(x, ya, zb), Vector3(x, yb, zb), Vector3(x, yb, za), Vector3(sx, 0, 0))


static func _doors(d: Dictionary, sh: Dictionary, hw: float, floor_y: float, y0: float,
		wall_top: float, z0: float, z1: float, style: String, integral: bool) -> void:
	var b: Dictionary = d["body"]
	var dk: _K = sh["door"]
	var tk: _K = sh["trim"]
	var house: Dictionary = d["house"]
	var side := str(b["side_door"])
	if side != "none":
		var w := 1.25 if side == "slider" else (0.85 if side == "bus" else 0.72)
		var dz0 := float(house["z0"]) + 0.2
		if side == "bus":
			dz0 = z0 + 0.1 if integral else float(house["z0"]) + 0.1
		elif style == "full_van":
			dz0 = float(house["z0"]) - 0.25
		var dz1 := minf(dz0 + w, z1 - 0.3)
		var dy0 := y0 + 0.03
		var dy1 := minf(wall_top - 0.05, floor_y + 1.95)
		var x := hw + 0.006
		dk.quad(Vector3(x, dy0, dz0), Vector3(x, dy0, dz1), Vector3(x, dy1, dz1), Vector3(x, dy1, dz0), Vector3.RIGHT)
		# Its outline + handle.
		for zz in [dz0, dz1]:
			tk.box(Vector3(x + 0.002, (dy0 + dy1) * 0.5, zz), Vector3(0.006, dy1 - dy0, 0.03))
		tk.box(Vector3(x + 0.015, floor_y + 0.95, dz1 - 0.12), Vector3(0.02, 0.04, 0.14))
		if side == "bus":
			(sh["glass"] as _K).quad(Vector3(x + 0.002, floor_y + 0.9, dz0 + 0.06),
				Vector3(x + 0.002, floor_y + 0.9, dz1 - 0.06), Vector3(x + 0.002, dy1 - 0.1, dz1 - 0.06),
				Vector3(x + 0.002, dy1 - 0.1, dz0 + 0.06), Vector3.RIGHT)
	var rear := str(b["rear_door"])
	if rear == "none":
		return
	var rz := z1 + 0.008
	var ry0 := floor_y - 0.05
	var ry1 := minf(wall_top - 0.08, floor_y + (2.2 if rear == "barn" else 2.4))
	var rw := hw - 0.08
	dk.quad(Vector3(-rw, ry0, rz), Vector3(rw, ry0, rz), Vector3(rw, ry1, rz), Vector3(-rw, ry1, rz), Vector3.BACK)
	match rear:
		"barn":
			tk.box(Vector3(0, (ry0 + ry1) * 0.5, rz + 0.004), Vector3(0.025, ry1 - ry0, 0.006))
			for sx in [-1.0, 1.0]:
				(sh["glass"] as _K).quad(Vector3(sx * 0.12, ry1 - 0.75, rz + 0.004),
					Vector3(sx * (rw - 0.1), ry1 - 0.75, rz + 0.004), Vector3(sx * (rw - 0.1), ry1 - 0.12, rz + 0.004),
					Vector3(sx * 0.12, ry1 - 0.12, rz + 0.004), Vector3.BACK)
		"roll_up":
			var y := ry0 + 0.12
			while y < ry1:
				tk.box(Vector3(0, y, rz + 0.004), Vector3(rw * 2.0, 0.012, 0.006))
				y += 0.16
		"lift":
			tk.box(Vector3(0, ry1 - 0.02, rz + 0.004), Vector3(rw * 2.0, 0.03, 0.006))


# --- floor + interior ------------------------------------------------------------------

static func _floor_and_interior(d: Dictionary, g: Dictionary) -> void:
	var house: Dictionary = d["house"]
	var fy := float(house["floor_y"])
	var hz0 := float(house["z0"])
	var hz1 := float(house["z1"])
	var hw := float(house["w"]) * 0.5
	(g["floor"] as _K).box(Vector3(0, fy - 0.03, (hz0 + hz1) * 0.5), Vector3(hw * 2.0, 0.06, hz1 - hz0))
	# Under the floor, the body's sill down to its bottom (no see-through gap
	# over the frame on a box body).
	for e in d["interior"]:
		_element(e as Dictionary, g, fy)


static func _element(e: Dictionary, g: Dictionary, fy: float) -> void:
	var type := str(e["type"])
	var x := float(e["x"])
	var z := float(e["z"])
	var fx := float(e["fx"])
	var fz := float(e["fz"])
	var y0 := float(e["base_y"])
	var y1 := float(e["top_y"])
	var wood: _K = g["wood"]
	var fab: _K = g["fabric"]
	var white: _K = g["white"]
	var dark: _K = g["dark"]
	match type:
		"bed", "cabover_bed":
			var mt := VehicleDesign.MATTRESS_T
			wood.box(Vector3(x, (y0 + y1 - mt) * 0.5, z), Vector3(fx, maxf(y1 - mt - y0, 0.04), fz))
			fab.box(Vector3(x, y1 - mt * 0.5, z), Vector3(fx - 0.04, mt, fz - 0.04))
			var along_z := fz >= fx
			var head := Vector3(x, y1 + 0.05, z - fz * 0.5 + 0.25) if along_z \
				else Vector3(x - fx * 0.5 + 0.25, y1 + 0.05, z)
			var psize := Vector3(minf(fx - 0.15, 0.55), 0.1, 0.32) if along_z \
				else Vector3(0.32, 0.1, minf(fz - 0.15, 0.55))
			(g["pillow"] as _K).box(head, psize)
		"bunk":
			for top in [y0 + 0.45, y1]:
				wood.box(Vector3(x, top - 0.2, z), Vector3(fx, 0.06, fz))
				fab.box(Vector3(x, top - 0.07, z), Vector3(fx - 0.04, 0.12, fz - 0.04))
			for sz in [-1.0, 1.0]:
				wood.box(Vector3(x, (y0 + y1) * 0.5, z + sz * (fz * 0.5 - 0.03)), Vector3(fx, y1 - y0, 0.05))
		"dinette":
			for sz in [-1.0, 1.0]:
				var bz: float = z + sz * (fz * 0.5 - 0.22)
				wood.box(Vector3(x, y0 + 0.21, bz), Vector3(fx, 0.42, 0.44))
				fab.box(Vector3(x, y0 + 0.47, bz), Vector3(fx - 0.04, 0.08, 0.42))
				fab.box(Vector3(x, y0 + 0.75, z + sz * (fz * 0.5 - 0.03)), Vector3(fx - 0.04, 0.5, 0.07))
			wood.box(Vector3(x, y1 - 0.02, z), Vector3(fx * 0.85, 0.04, fz - 0.95))
			dark.cylinder(Vector3(x, (y0 + y1) * 0.5, z), 0.03, y1 - y0, Vector3.UP, 8)
		"bench", "sofa":
			wood.box(Vector3(x, y0 + 0.2, z), Vector3(fx, 0.4, fz))
			fab.box(Vector3(x, y0 + 0.45, z), Vector3(fx - 0.03, 0.1, fz - 0.03))
			if type == "sofa":
				var bx := x + (0.32 if x > 0.0 else -0.32) * (fx / 0.75)
				fab.box(Vector3(bx, y0 + 0.62, z), Vector3(0.14, 0.45, fz - 0.04))
		"table":
			wood.box(Vector3(x, y1 - 0.02, z), Vector3(fx, 0.04, fz))
			dark.cylinder(Vector3(x, (y0 + y1) * 0.5, z), 0.03, y1 - y0, Vector3.UP, 8)
		"galley", "workbench":
			wood.box(Vector3(x, (y0 + y1) * 0.5 - 0.02, z), Vector3(fx, y1 - y0 - 0.04, fz))
			var top_k: _K = dark if type == "workbench" else white
			top_k.box(Vector3(x, y1 - 0.02, z), Vector3(fx + 0.02, 0.04, fz + 0.02))
			if type == "galley":
				var along := fz >= fx
				var sink := Vector3(x, y1 + 0.002, z - fz * 0.22) if along else Vector3(x - fx * 0.22, y1 + 0.002, z)
				var stove := Vector3(x, y1 + 0.004, z + fz * 0.22) if along else Vector3(x + fx * 0.22, y1 + 0.004, z)
				(g["mirror"] as _K).box(sink, Vector3(minf(fx, fz) * 0.6, 0.006, 0.38))
				dark.box(stove, Vector3(minf(fx, fz) * 0.6, 0.012, 0.42))
		"fridge":
			white.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
			dark.box(Vector3(x + (-fx * 0.5 - 0.003 if x > 0.0 else fx * 0.5 + 0.003), y1 - 0.25, z),
				Vector3(0.006, 0.3, 0.03))
		"shower":
			white.box(Vector3(x, y0 + 0.04, z), Vector3(fx, 0.08, fz))
			for sx in [-1.0, 1.0]:
				white.box(Vector3(x + sx * (fx * 0.5 - 0.02), (y0 + y1) * 0.5, z), Vector3(0.04, y1 - y0, fz))
			white.box(Vector3(x, (y0 + y1) * 0.5, z - fz * 0.5 + 0.02), Vector3(fx, y1 - y0, 0.04))
			(g["mirror"] as _K).cylinder(Vector3(x, y1 - 0.25, z), 0.08, 0.02, Vector3.UP, 10)
		"shoilet":
			white.box(Vector3(x, y0 + 0.04, z), Vector3(fx, 0.08, fz))
			for sx in [-1.0, 1.0]:
				white.box(Vector3(x + sx * (fx * 0.5 - 0.02), (y0 + y1) * 0.5, z), Vector3(0.04, y1 - y0, fz))
			white.box(Vector3(x, (y0 + y1) * 0.5, z + fz * 0.5 - 0.02), Vector3(fx, y1 - y0, 0.04))
			white.box(Vector3(x, y0 + 0.22, z - fz * 0.2), Vector3(0.38, 0.36, 0.42))
			wood.box(Vector3(x, y0 + 0.42, z - fz * 0.2), Vector3(0.4, 0.04, 0.44))
		"toilet":
			white.box(Vector3(x, y0 + 0.2, z), Vector3(fx * 0.8, 0.4, fz * 0.75))
			wood.box(Vector3(x, y0 + 0.42, z), Vector3(fx * 0.85, 0.04, fz * 0.8))
		"cabinet", "cubby":
			wood.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
			var front_x := x + (-fx * 0.5 - 0.004 if x > 0.0 else fx * 0.5 + 0.004)
			var hy := y0 + (y1 - y0) * 0.5
			dark.box(Vector3(front_x, hy, z), Vector3(0.006, 0.012, fz * 0.9))
		"wall":
			wood.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"battery":
			dark.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"inverter":
			(g["trim"] as _K).box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"water_tank", "grey_tank":
			white.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"light":
			(g["lamp"] as _K).cylinder(Vector3(x, y0 + 0.015, z), maxf(fx, fz) * 0.5, 0.03, Vector3.UP, 12)
		"monitor":
			dark.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"mirror":
			(g["mirror"] as _K).box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		_:
			wood.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))


# --- helpers ---------------------------------------------------------------------------

## A side profile (z, y) extruded across `width`, centred on x = 0: both side
## faces triangulated, every edge a quad.
static func _extrude_side(k: _K, prof: PackedVector2Array, width: float) -> void:
	var hw := width * 0.5
	var idx := Geometry2D.triangulate_polygon(prof)
	for i in range(0, idx.size(), 3):
		var a := prof[idx[i]]
		var b := prof[idx[i + 1]]
		var c := prof[idx[i + 2]]
		k.tri(Vector3(hw, a.y, a.x), Vector3(hw, b.y, b.x), Vector3(hw, c.y, c.x), Vector3.RIGHT)
		k.tri(Vector3(-hw, a.y, a.x), Vector3(-hw, b.y, b.x), Vector3(-hw, c.y, c.x), Vector3.LEFT)
	var ccw := _signed_area(prof) > 0.0
	var n := prof.size()
	for i in n:
		var p := prof[i]
		var q := prof[(i + 1) % n]
		var e := q - p
		if e.length() < 1e-5:
			continue
		# Outward normal in (z, y): the right-hand perpendicular of a CCW edge.
		var nz := e.y if ccw else -e.y
		var ny := -e.x if ccw else e.x
		var nrm := Vector3(0, ny, nz).normalized()
		k.quad(Vector3(-hw, p.y, p.x), Vector3(hw, p.y, p.x), Vector3(hw, q.y, q.x), Vector3(-hw, q.y, q.x), nrm)


static func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var u := p[i]
		var v := p[(i + 1) % p.size()]
		a += u.x * v.y - v.x * u.y
	return a * 0.5


## A windshield: a quad across `width` between two (z, y) points, a hair in
## front of the face it sits on.
static func _glass_slope(k: _K, lo: Vector2, hi: Vector2, width: float) -> void:
	var hw := width * 0.5
	var e := hi - lo
	var nrm := Vector3(0, -e.x, e.y).normalized()
	if nrm.z > 0.0:
		nrm = -nrm
	var off := nrm * 0.006
	k.quad(Vector3(-hw, lo.y, lo.x) + off, Vector3(hw, lo.y, lo.x) + off,
		Vector3(hw, hi.y, hi.x) + off, Vector3(-hw, hi.y, hi.x) + off, nrm)


static func _side_windows(k: _K, za: float, zb: float, ya: float, yb: float, width: float) -> void:
	if zb - za < 0.1 or yb - ya < 0.1:
		return
	var hw := width * 0.5
	for sx in [-1.0, 1.0]:
		var x: float = sx * (hw + 0.004)
		k.quad(Vector3(x, ya, za), Vector3(x, ya, zb), Vector3(x, yb, zb), Vector3(x, yb, za), Vector3(sx, 0, 0))


static func _plain(c: Color, metallic: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	return m


static func _emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := _plain(c, 0.0, 0.4)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


static func _commit(k: _K, mesh: ArrayMesh, mat: Material) -> void:
	if k.count == 0:
		return
	k.st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


## One surface's emitter. tri() orders corners clockwise seen from `facing`
## (Godot's front face); quad_n() carries a normal per corner for the rounded
## shell.
class _K:
	var st := SurfaceTool.new()
	var count := 0

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func tri_n(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
			facing: Vector3) -> void:
		if (b - a).cross(c - a).dot(facing) > 0.0:
			var t := b
			b = c
			c = t
			var tn := nb
			nb = nc
			nc = tn
		st.set_normal(na)
		st.add_vertex(a)
		st.set_normal(nb)
		st.add_vertex(b)
		st.set_normal(nc)
		st.add_vertex(c)
		count += 1

	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
		tri_n(a, b, c, n, n, n, n)

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		tri(a, b, c, n)
		tri(a, c, d, n)

	func quad_n(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3,
			nc: Vector3, nd: Vector3, facing: Vector3) -> void:
		tri_n(a, b, c, na, nb, nc, facing)
		tri_n(a, c, d, na, nc, nd, facing)

	func box(center: Vector3, size: Vector3) -> void:
		obox(center, Vector3(size.x * 0.5, 0, 0), Vector3(0, size.y * 0.5, 0), Vector3(0, 0, size.z * 0.5))

	func obox(center: Vector3, ax: Vector3, ay: Vector3, az: Vector3) -> void:
		var axes := [ax, ay, az]
		for i in 3:
			var u: Vector3 = axes[i]
			var v: Vector3 = axes[(i + 1) % 3]
			var w: Vector3 = axes[(i + 2) % 3]
			if u.length_squared() < 1e-12:
				continue
			for s in [-1.0, 1.0]:
				var fc: Vector3 = center + u * s
				var n: Vector3 = (u * s).normalized()
				quad(fc - v - w, fc + v - w, fc + v + w, fc - v + w, n)

	func cylinder(center: Vector3, r: float, h: float, axis: Vector3 = Vector3.UP,
			sides: int = 20) -> void:
		axis = axis.normalized()
		var ref := Vector3.RIGHT if absf(axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
		var e1 := axis.cross(ref).normalized()
		var e2 := axis.cross(e1).normalized()
		var top := center + axis * (h * 0.5)
		var bot := center - axis * (h * 0.5)
		for i in sides:
			var a0 := TAU * float(i) / sides
			var a1 := TAU * float(i + 1) / sides
			var d0 := e1 * cos(a0) + e2 * sin(a0)
			var d1 := e1 * cos(a1) + e2 * sin(a1)
			quad_n(bot + d0 * r, bot + d1 * r, top + d1 * r, top + d0 * r, d0, d1, d1, d0, (d0 + d1).normalized())
			tri(top, top + d0 * r, top + d1 * r, axis)
			tri(bot, bot + d1 * r, bot + d0 * r, -axis)

class_name WindLabBuilder
extends Node3D

## A designed wind turbine as a node: the blades (bent sheet, airfoil
## sections or a propeller's twisted blades — from WindLabMesh, the same
## triangles the STL files carry), the hub discs / end plates / arms, the
## shaft, bearings and drive, the generator, the mast and, for a propeller,
## the nacelle, yaw bearing and tail. Built from WindLabDesign.solve().
##
## Nodes (names are load-bearing — the world's WindLabRuntime and the
## studio drive them):
##   Machine          the whole turbine in the model frame (ground at y = 0)
##   Machine/Static   mast, foot, bearing housings, a fixed generator
##   Machine/Yaw      a propeller's nacelle, tail and rotor (turns about +Y
##                    to face the wind; absent for a vertical axis rotor)
##   …/Rotor          what spins: +Y for a vertical axis rotor, +Z (the
##                    nacelle's downwind axis) for a propeller
##   Machine/GenSpin  the generator-side pulley / gear (turns at the ratio)
## The spinning parts carry skip_prop_collision; the mast and the static
## parts are the placed prop's collision.

const MODEL_ID := "windlab_turbine"
const MM := 0.001
## STL frame (mm, Z up) → Godot (m, Y up): x → x, y → −z, z → y.
const STL_TO_GODOT := Basis(Vector3(MM, 0, 0), Vector3(0, 0, -MM), Vector3(0, MM, 0))

var _d: Dictionary = {}
var _machine: Node3D = null
var _rotor: Node3D = null
var _yaw: Node3D = null
var _gen_spin: Node3D = null
var _rotor_axis := Vector3.UP
var _spin_rpm := -1.0
var _angle := 0.0
var _gen_angle := 0.0
var _yaw_rad := 0.0
var _picks: Array = []
var _ghost := false
var _gen_at := Vector3.ZERO

static var _mats: Dictionary = {}


static func build_node(spec: Dictionary = {}, node_name: String = "WindTurbine", opts: Dictionary = {}) -> Node3D:
	return build_from_design(WindLabDesign.solve(spec), node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "WindTurbine", opts: Dictionary = {}) -> Node3D:
	var b := WindLabBuilder.new()
	b.name = node_name
	b._ghost = bool(opts.get("ghost_highlight", false))
	b._build(d)
	b.set_meta("windlab_spec", WindLabSpec.to_json_safe(d["spec"]))
	return b


func design() -> Dictionary:
	return _d


func rotor() -> Node3D:
	return _rotor


func yaw_node() -> Node3D:
	return _yaw


## The studio (and the world runtime) spin the rotor at this speed;
## rpm < 0 leaves it where it is.
func set_spin_rpm(rpm: float) -> void:
	_spin_rpm = rpm
	set_process(rpm >= 0.0)


## Turn a propeller to face a bearing (radians about +Y; 0 = facing −Z).
func set_yaw(rad: float) -> void:
	_yaw_rad = rad
	if _yaw != null:
		_yaw.rotation.y = rad


func set_rotor_angle(a: float) -> void:
	_angle = a
	_apply_angles()


func _process(delta: float) -> void:
	if _spin_rpm < 0.0 or _rotor == null:
		return
	var w := _spin_rpm * TAU / 60.0 * float(_d.get("spin_dir", 1.0))
	_angle = wrapf(_angle + w * delta, -TAU, TAU)
	_apply_angles()


func _apply_angles() -> void:
	if _rotor != null:
		_rotor.transform.basis = Basis(_rotor_axis, _angle)
	if _gen_spin != null:
		var g := float(_d.get("ratio", 1.0))
		_gen_spin.transform.basis = Basis(Vector3.UP, wrapf(_angle * g, -TAU * 100.0, TAU * 100.0))


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build(d: Dictionary) -> void:
	_d = d
	_picks.clear()
	_machine = Node3D.new()
	_machine.name = "Machine"
	add_child(_machine)
	var stat := {}
	var rot := {}
	var gen_sts := {}
	var yaw_sts := {}
	if bool(d["vawt"]):
		_build_vawt(d, stat, rot, gen_sts)
	else:
		_build_hawt(d, stat, rot, yaw_sts)
	var smi := _commit(stat, "Static", false)
	_machine.add_child(smi)
	if not gen_sts.is_empty():
		_gen_spin = Node3D.new()
		_gen_spin.name = "GenSpin"
		_gen_spin.position = _gen_at
		_machine.add_child(_gen_spin)
		_gen_spin.add_child(_commit(gen_sts, "GenParts", true))
	if _yaw != null:
		_yaw.add_child(_commit(yaw_sts, "Nacelle", false))
	if _rotor != null:
		_rotor.add_child(_commit(rot, "RotorParts", true))
	set_meta("windlab_picks", _picks)
	set_process(false)


static func _st(sts: Dictionary, key: String) -> SurfaceTool:
	return GantryLabDetail._st(sts, key)


## Add STL-frame triangles (mm, CCW outside) through xf (STL → node local,
## basis carrying the mm → m scale), wound clockwise for Godot.
static func add_tris(st: SurfaceTool, tris: PackedVector3Array, xf: Transform3D) -> void:
	var nb := xf.basis.orthonormalized()
	for i in range(0, tris.size() - 2, 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-12:
			continue
		var ng := (nb * n).normalized()
		# GantryLabDetail's emitters write a UV on every vertex into the same
		# SurfaceTools; every vertex must carry the same attributes.
		st.set_normal(ng)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(xf * a)
		st.set_normal(ng)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(xf * c)
		st.set_normal(ng)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(xf * b)


func _pick(label: String, box: AABB) -> void:
	_picks.append({"label": label, "aabb": box})


func _mast(d: Dictionary, stat: Dictionary, top: float) -> void:
	var s: Dictionary = d["spec"]
	var mast := WindLabParts.mast(str(s["mount"]["mast"]))
	var r := float(mast["od"]) * 0.0005
	GantryLabDetail._xf = Transform3D.IDENTITY
	GantryLabDetail.cyl_y(_st(stat, "frame"), 0.0, top, r, 16)
	# A foot plate (or a ground stake's point for a rod).
	if float(mast["od"]) >= 20.0:
		GantryLabDetail.box(_st(stat, "frame"), Vector3(0, 0.005, 0), Vector3(r * 6.0, 0.01, r * 6.0))
	_pick("%s, %s" % [str(mast["label"]), WindLabSpec.fmt_len(top * 1000.0)], AABB(Vector3(-r, 0, -r), Vector3(2 * r, top, 2 * r)))
	if bool(s["mount"].get("guyed", false)) and top > 1.5:
		# Three guy wires from two-thirds up to anchors a half-height out.
		var gy := top * 0.66
		for k in 3:
			var a := TAU * float(k) / 3.0 + 0.3
			var foot := Vector3(cos(a), 0.0, sin(a)) * top * 0.5
			GantryLabDetail.cyl(_st(stat, "chrome"), Vector3(0, gy, 0), foot, 0.003, 6)
			GantryLabDetail.box(_st(stat, "frame"), foot + Vector3(0, 0.03, 0), Vector3(0.06, 0.06, 0.06))


func _build_vawt(d: Dictionary, stat: Dictionary, rot: Dictionary, gen_sts: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["rotor"]
	var t := str(s["type"])
	var lay: Dictionary = d["layout"]
	var mtop := float(lay["mast_top"])
	var yb := float(lay["rotor_bottom"])
	var h := float(r["h_mm"])
	var gen: Dictionary = d["gen"]
	var style := str(s["mount"]["style"])
	_mast(d, stat, mtop)
	_rotor = Node3D.new()
	_rotor.name = "Rotor"
	_rotor.position = Vector3(0.0, yb, 0.0)
	_rotor_axis = Vector3.UP
	_machine.add_child(_rotor)
	var xf := Transform3D(STL_TO_GODOT, Vector3.ZERO)
	var tsh := float(d["sheet_t_mm"])
	var R_mm := float(d["tip_r_mm"])
	var stages := int(r["stages"])
	var hs := h / float(stages)
	if t in ["ugrinsky", "savonius", "lenz2"]:
		var twist := deg_to_rad(float(r["twist_deg"])) / float(stages)
		for k in stages:
			var z0 := hs * float(k)
			var off := (PI * 0.5 if int(r["blades"]) == 2 else PI / float(int(r["blades"]))) * float(k)
			for b in d["blades"]:
				var pts: PackedVector2Array = b["pts"]
				var p2 := PackedVector2Array()
				for p in pts:
					p2.append(p.rotated(off))
				add_tris(_st(rot, "blade"), WindLabMesh.sheet_blade(p2, tsh, z0, z0 + hs, twist), xf)
				if t == "lenz2":
					var le := p2[0]
					var lr := float(r["chord_frac"]) * float(r["d_mm"]) * 0.05
					add_tris(_st(rot, "blade"), WindLabMesh.transformed(WindLabMesh.ring(lr, 0.0, z0, z0 + hs, 12),
						Transform3D(Basis.IDENTITY, Vector3(le.x, le.y, 0.0))), xf)
		var hub_style := str(r["hub"]["style"])
		var disc_r := R_mm * float(r["hub"]["overhang"])
		var heights: Array = []
		match hub_style:
			"mid_discs":
				var n := int(r["hub"]["count"])
				var sp := float(r["hub"]["spacing_mm"])
				for i in n:
					heights.append(h * 0.5 + (float(i) - float(n - 1) * 0.5) * sp)
			"end_plates":
				for k in stages + 1:
					heights.append(hs * float(k) - (tsh if k == 0 else 0.0))
			"spokes":
				for k in stages:
					heights.append(hs * (float(k) + 0.2))
					heights.append(hs * (float(k) + 0.8))
		if hub_style == "spokes":
			var hr := WindLabDesign._foil_hub_r_mm(d)
			for z in heights:
				add_tris(_st(rot, "hub"), WindLabMesh.ring(hr, 0.0, float(z) - tsh, float(z) + tsh, 24), xf)
				for b in d["blades"]:
					var pts2: PackedVector2Array = b["pts"]
					var mid := pts2[pts2.size() / 2]
					GantryLabDetail._xf = Transform3D.IDENTITY
					GantryLabDetail.bar(_st(rot, "frame"), Vector3(0, float(z) * MM, 0),
						Vector3(mid.x * MM, float(z) * MM, -mid.y * MM), maxf(float(r["d_mm"]) * 0.04, 30.0) * MM, 4.0 * MM)
		else:
			for z in heights:
				add_tris(_st(rot, "hub"), WindLabMesh.ring(disc_r, 0.0, float(z), float(z) + tsh, 64), xf)
		_pick("Blades (%d × %s)" % [int(r["blades"]) * stages, str(WindLabParts.sheet(str(s["build"]["sheet"]))["label"])],
			AABB(Vector3(-R_mm * MM, yb, -R_mm * MM), Vector3(2 * R_mm * MM, h * MM, 2 * R_mm * MM)))
	else:
		# Darrieus / helical: airfoil blades on arms.
		var af := WindLabAero.airfoil_points(WindLabParts.airfoil(str(r["airfoil"])), 16)
		var hel := deg_to_rad(float(r["helix_deg"])) if t == "helical" else 0.0
		var layers := 1 if hel == 0.0 else maxi(int(ceil(rad_to_deg(hel) / 4.0)), 4)
		var R := float(r["d_mm"]) * 0.5
		var nb := int(r["blades"])
		for k in nb:
			var psi := TAU * float(k) / float(nb)
			add_tris(_st(rot, "blade"), WindLabMesh.vawt_foil_blade(af, float(r["chord_mm"]), R, psi, 0.0, h, hel, layers), xf)
		var arms := int(r["arms"])
		var hr2 := WindLabDesign._foil_hub_r_mm(d)
		for ai in arms:
			var u := (float(ai) + 0.5) / float(arms) if arms > 2 else (0.5 if arms == 1 else (0.18 if ai == 0 else 0.82))
			var z2 := h * u
			add_tris(_st(rot, "hub"), WindLabMesh.ring(hr2, 0.0, z2 - 6.0, z2 + 6.0, 24), xf)
			for k in nb:
				var a := TAU * float(k) / float(nb) + hel * u
				GantryLabDetail._xf = Transform3D.IDENTITY
				GantryLabDetail.bar(_st(rot, "frame"), Vector3(cos(a) * hr2 * MM, z2 * MM, -sin(a) * hr2 * MM),
					Vector3(cos(a) * (R - 10.0) * MM, z2 * MM, -sin(a) * (R - 10.0) * MM), maxf(float(r["chord_mm"]) * 0.5, 25.0) * MM, 5.0 * MM)
		_pick("Blades (%d × %s %s)" % [nb, str(WindLabParts.airfoil(str(r["airfoil"]))["label"]), str(WindLabParts.solid(str(s["build"]["solid"]))["label"])],
			AABB(Vector3(-R * MM, yb, -R * MM), Vector3(2 * R * MM, h * MM, 2 * R * MM)))
	# Shaft, generator, drive.
	var glen := float(gen["len_mm"]) * MM
	match style:
		"body_spins":
			# The motor is clamped to the hub discs and turns with the rotor; its
			# shaft points down into a coupler on the mast top.
			var face := float(lay["gen_face"])
			var local := Vector3(0.0, face - yb, 0.0)
			_emit_gen(rot, gen, local, Vector3.DOWN)
			GantryLabDetail._xf = Transform3D.IDENTITY
			GantryLabDetail.cyl_y(_st(stat, "alu"), mtop - 0.012, mtop + 0.012, 0.009, 14)
			_pick("%s (its body turns with the rotor)" % str(gen["label"]), AABB(Vector3(-0.03, face, -0.03), Vector3(0.06, glen, 0.06)))
		"on_shaft":
			var face2 := float(lay["gen_face"])
			_emit_gen(stat, gen, Vector3(0.0, face2, 0.0), Vector3.UP)
			GantryLabDetail._xf = Transform3D.IDENTITY
			GantryLabDetail.cyl_y(_st(rot, "chrome"), -0.02, h * MM * 0.25, float(gen["shaft_mm"]) * 0.0005 + 0.002, 10)
			_pick(str(gen["label"]), AABB(Vector3(-0.06, face2 - glen, -0.06), Vector3(0.12, glen, 0.12)))
		"bearings":
			var sd := float(s["mount"]["shaft_d_mm"]) * MM
			GantryLabDetail._xf = Transform3D.IDENTITY
			GantryLabDetail.cyl_y(_st(rot, "chrome"), mtop - yb - 0.06, h * MM + 0.03, sd * 0.5, 12)
			var bg: Dictionary = d["bearing"]
			var bod := float(bg.get("od", 22.0)) * MM
			for by in [mtop + 0.01, yb - 0.02]:
				GantryLabDetail.box(_st(stat, "cast"), Vector3(0, float(by), 0), Vector3(bod * 2.2, 0.025, bod * 2.2))
			_pick("Bearings %s on a Ø %.0f mm shaft" % [str(bg.get("id", "")), sd * 1000.0], AABB(Vector3(-bod, mtop, -bod), Vector3(2 * bod, yb - mtop, 2 * bod)))
			var dt := str(s["drive"]["type"])
			var pd1 := maxf(float(d["driver_pd_mm"]), 40.0) * MM
			var pd2 := maxf(float(d["driven_pd_mm"]), 15.0) * MM
			var py := mtop + 0.045
			if dt != "direct":
				# The rotor's pulley on the shaft, the generator's beside the mast.
				GantryLabDetail.cyl_y(_st(rot, "alu"), py - yb - 0.01, py - yb + 0.01, pd1 * 0.5, 32)
				var cx := pd1 * 0.5 + pd2 * 0.5 + 0.08
				var gpos := Vector3(cx, py, 0.0)
				_gen_at = gpos
				GantryLabDetail._xf = Transform3D.IDENTITY
				GantryLabDetail.cyl_y(_st(gen_sts, "alu"), -0.01, 0.01, pd2 * 0.5, 24)
				_emit_gen(stat, gen, Vector3(cx, py - 0.02, 0.0), Vector3.UP)
				# The belt: two straight runs (the loop round each pulley is hidden
				# under the flanges).
				if dt in ["gt2", "htd5"]:
					for sgn in [-1.0, 1.0]:
						GantryLabDetail.box_ab(_st(stat, "belt"), Vector3(0.0, py - 0.004, sgn * pd1 * 0.5 - 0.001),
							Vector3(cx, py + 0.004, sgn * pd2 * 0.5 + 0.001))
				else:
					GantryLabDetail.box(_st(stat, "steel"), Vector3(cx * 0.5, py, 0.0), Vector3(cx, 0.03, 0.04))
				_pick("%s, %s %.2f : 1" % [str(gen["label"]), str(WindLabParts.DRIVES[dt]["label"]), float(d["ratio"])],
					AABB(Vector3(cx - 0.06, py - glen, -0.06), Vector3(0.12, glen + 0.03, 0.12)))
			else:
				_emit_gen(stat, gen, Vector3(0.0, mtop - 0.02, 0.0), Vector3.UP)


## A generator: a NEMA stepper (GantryLabDetail's motor — mounting face at
## `at`, shaft along `up`), or a can / hub / alternator body hanging behind it.
func _emit_gen(sts: Dictionary, gen: Dictionary, at: Vector3, up: Vector3) -> void:
	var glen := float(gen["len_mm"]) * MM
	match str(gen["body"]):
		"nema":
			GantryLabDetail.emit(sts, {"kind": "motor", "c": at, "basis": GantryLabDetail.basis_y(up),
				"frame": float(gen["frame_mm"]) * MM, "len": glen, "shaft": 0.02})
		_:
			var r := float(gen.get("dia_mm", 100.0)) * 0.0005
			GantryLabDetail._xf = Transform3D(GantryLabDetail.basis_y(up), at)
			GantryLabDetail.cyl_y(_st(sts, "motor"), -glen, 0.0, r, 32)
			GantryLabDetail.cyl_y(_st(sts, "alu"), -0.006, 0.0, r * 1.04, 32)
			GantryLabDetail.cyl_y(_st(sts, "chrome"), 0.0, 0.03, float(gen["shaft_mm"]) * 0.0005, 10)
			GantryLabDetail._xf = Transform3D.IDENTITY


func _build_hawt(d: Dictionary, stat: Dictionary, rot: Dictionary, yaw_sts: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var r: Dictionary = s["rotor"]
	var lay: Dictionary = d["layout"]
	var mtop := float(lay["mast_top"])
	var hub_y := float(lay["hub"]) - mtop
	var gen: Dictionary = d["gen"]
	_mast(d, stat, mtop)
	_yaw = Node3D.new()
	_yaw.name = "Yaw"
	_yaw.position = Vector3(0.0, mtop, 0.0)
	_machine.add_child(_yaw)
	# Yaw collar, the generator along +Z (downwind) behind the hub.
	GantryLabDetail._xf = Transform3D.IDENTITY
	GantryLabDetail.cyl_y(_st(yaw_sts, "cast"), -0.04, 0.05, 0.045, 20)
	var glen := float(gen["len_mm"]) * MM
	var gdia := float(gen.get("dia_mm", gen.get("frame_mm", 80.0))) * MM
	var front := -0.05
	_emit_gen(yaw_sts, gen, Vector3(0.0, hub_y, front), Vector3.FORWARD)
	GantryLabDetail.box_ab(_st(yaw_sts, "frame"), Vector3(-0.03, 0.04, -0.02), Vector3(0.03, hub_y - gdia * 0.4, glen * 0.8))
	# Tail: boom + vane (≈ 6 % of the swept area, boom 0.6 D).
	var tl := WindLabDesign.tail(d)
	var boom := float(tl["boom_mm"]) * MM
	if bool(r["tail"]):
		GantryLabDetail.bar(_st(yaw_sts, "frame"), Vector3(0, hub_y, glen * 0.6), Vector3(0, hub_y + boom * 0.15, boom), 0.025, 0.025)
		var va := float(tl["vane_cm2"]) * 1e-4
		var vh := sqrt(va / 1.5)
		var vl := vh * 1.5
		GantryLabDetail.box(_st(yaw_sts, "vane"), Vector3(0, hub_y + boom * 0.15 + vh * 0.2, boom - vl * 0.4), Vector3(0.004, vh, vl))
		_pick("Tail vane %.0f cm², boom %.0f mm" % [float(tl["vane_cm2"]), float(tl["boom_mm"])],
			AABB(Vector3(-0.01, mtop + hub_y, boom - vl), Vector3(0.02, vh * 1.5, vl)))
	_pick(str(gen["label"]), AABB(Vector3(-gdia * 0.5, mtop + hub_y - gdia * 0.5, front), Vector3(gdia, gdia, glen)))
	# The rotor on the generator's shaft, in front.
	_rotor = Node3D.new()
	_rotor.name = "Rotor"
	_rotor.position = Vector3(0.0, hub_y, front - 0.035)
	_rotor_axis = Vector3.BACK
	_yaw.add_child(_rotor)
	var hr := WindLabDesign._foil_hub_r_mm(d)
	var hub_xf := Transform3D(Basis(Vector3(MM, 0, 0), Vector3(0, MM, 0), Vector3(0, 0, MM)), Vector3.ZERO)
	add_tris(_st(rot, "hub"), WindLabMesh.ring(hr, 0.0, -10.0, 10.0, 36), hub_xf)
	# Spinner nose.
	GantryLabDetail._xf = Transform3D(GantryLabDetail.basis_y(Vector3.FORWARD), Vector3(0, 0, -0.01))
	GantryLabDetail.lathe(_st(rot, "hub"), PackedVector2Array([Vector2(hr * MM * 0.7, 0.0), Vector2(hr * MM * 0.5, hr * MM * 0.5),
		Vector2(0.0, hr * MM * 0.9)]), 24)
	GantryLabDetail._xf = Transform3D.IDENTITY
	var af_id := "curved_plate" if str(s["type"]) == "multiblade" else ""
	var af := WindLabAero.airfoil_points(WindLabParts.airfoil(af_id) if not af_id.is_empty() else WindLabAero.hawt_airfoil(s), 16)
	var stations: Array = d["stations"]
	var nb := int(r["blades"])
	var thick_k := 1.0
	var blade := WindLabMesh.hawt_blade(stations, af, thick_k)
	for k in nb:
		var psi := TAU * float(k) / float(nb)
		var er := Vector3(cos(psi), sin(psi), 0.0)
		var et := Vector3(-sin(psi), cos(psi), 0.0)
		var bxf := Transform3D(Basis(er * MM, et * MM, Vector3.BACK * MM), Vector3.ZERO)
		add_tris(_st(rot, "blade"), blade, bxf)
	if str(s["type"]) == "multiblade":
		# The rim tying the plate tips.
		var R := float(d["R_m"])
		for k in 48:
			var a0 := TAU * float(k) / 48.0
			var a1 := TAU * float(k + 1) / 48.0
			GantryLabDetail.cyl(_st(rot, "frame"), Vector3(cos(a0), sin(a0), 0.0) * R * 0.98, Vector3(cos(a1), sin(a1), 0.0) * R * 0.98, 0.006, 6)
	var Rm := float(d["R_m"])
	_pick("Rotor: %d × %s blades, Ø %s" % [nb, str(WindLabAero.hawt_airfoil(s)["label"]), WindLabSpec.fmt_len(float(r["d_mm"]))],
		AABB(Vector3(-Rm, mtop + hub_y - Rm, front - 0.2), Vector3(2 * Rm, 2 * Rm, 0.25)))


# ---------------------------------------------------------------------------
# Meshes and materials
# ---------------------------------------------------------------------------

func _commit(sts: Dictionary, node_name: String, skip_collision: bool) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var keys: Array = sts.keys()
	keys.sort()
	for key in keys:
		var st: SurfaceTool = sts[key]
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(str(key)))
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	if skip_collision:
		mi.set_meta("skip_prop_collision", true)
	return mi


func _material(key: String) -> Material:
	var cols: Dictionary = _d["spec"]["colors"]
	var s: Dictionary = _d["spec"]
	var look := ""
	if key == "blade":
		var t := str(s["type"])
		if t in ["ugrinsky", "savonius", "lenz2", "multiblade"]:
			look = str(WindLabParts.sheet(str(s["build"]["sheet"]))["look"])
		elif t == "hawt" and str(s["rotor"]["construction"]) == "pvc_pipe":
			look = "pvc"
		else:
			look = str(WindLabParts.solid(str(s["build"]["solid"]))["look"])
	var ck := "%s|%s|%s|%s" % [key, look, str(cols.get(key, "")), "g" if _ghost else "s"]
	if _mats.has(ck):
		return _mats[ck]
	var m := _make_material(key, look, cols)
	if _ghost and m is StandardMaterial3D:
		var sm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color = Color(sm.albedo_color.r, sm.albedo_color.g, sm.albedo_color.b, 0.55)
		m = sm
	_mats[ck] = m
	return m


static func _plain(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	return m


func _make_material(key: String, look: String, cols: Dictionary) -> Material:
	match key:
		"blade":
			var c: Color = cols.get("blade", Color(0.93, 0.93, 0.9))
			match look:
				"alu":
					return _plain(Color(0.8, 0.81, 0.83), 0.85, 0.4)
				"galv":
					return StructureMaterials.make(StructureMaterials.Kind.GALVANISED, c)
				"ply", "wood":
					return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.72, 0.58, 0.4))
				"clear":
					var g := _plain(Color(0.85, 0.92, 0.95, 0.45), 0.0, 0.1)
					g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
					return g
				"cf":
					return _plain(Color(0.1, 0.1, 0.11), 0.2, 0.45)
			var pm := _plain(c, 0.0, 0.55)
			pm.cull_mode = BaseMaterial3D.CULL_DISABLED
			return pm
		"hub":
			var hc: Color = cols.get("hub", Color(0.86, 0.86, 0.84))
			var hm := _plain(hc, 0.0, 0.6)
			hm.cull_mode = BaseMaterial3D.CULL_DISABLED
			return hm
		"frame":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("frame", Color(0.35, 0.37, 0.4)))
		"motor", "gen":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("generator", Color(0.12, 0.13, 0.15)))
		"cast":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.27, 0.33, 0.38))
		"alu":
			return _plain(Color(0.8, 0.81, 0.83), 0.85, 0.35)
		"chrome":
			return _plain(Color(0.84, 0.85, 0.87), 0.95, 0.2)
		"steel":
			return _plain(Color(0.3, 0.31, 0.33), 0.75, 0.45)
		"belt", "black":
			return _plain(Color(0.06, 0.06, 0.06), 0.0, 0.9)
		"vane":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.8, 0.25, 0.15))
	return _plain(Color(0.5, 0.5, 0.5), 0.0, 0.7)


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## The part under a ray (world space): {label, distance} or {}.
static func pick(node: Node3D, origin: Vector3, dir: Vector3) -> Dictionary:
	if node == null or not node.has_meta("windlab_picks"):
		return {}
	var machine := node.get_node_or_null("Machine") as Node3D
	if machine == null:
		return {}
	var xf := node.global_transform * machine.transform if node.is_inside_tree() else node.transform * machine.transform
	var inv := xf.affine_inverse()
	var o := inv * origin
	var dv := (inv.basis * dir).normalized()
	var best := {}
	var best_t := INF
	for p in node.get_meta("windlab_picks"):
		var box: AABB = p["aabb"]
		var hit: Variant = box.intersects_ray(o, dv)
		if hit == null:
			continue
		var t := (hit as Vector3).distance_to(o)
		var score := t + box.size.length() * 0.25
		if score < best_t:
			best_t = score
			best = {"label": str(p["label"]), "distance": t}
	return best

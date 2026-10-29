class_name PeltonLabBuilder
extends Node3D

## A designed Pelton turbine as a node: the cups (the STL, one MultiMesh),
## the rotor discs, spacer ring, hub and every bolt, the shaft and key,
## bearings, the drive (coupler, V-belt, timing belt or gears), the
## generator, the nozzles, the housing and the base. Built from
## PeltonLabDesign.solve(); the design's CANONICAL frame (shaft +X) sits under
## a "Machine" node carrying the canonical → model transform.
##
## Nodes (names are load-bearing):
##   Machine/Runner     the cups + rotor (what spins; the world's
##                      SiphonTurbineSpin turns it about the model's spin
##                      axis, the studio turns it with set_spin_rpm)
##   Machine/ShaftSpin  the shaft, key, driver pulley / gear / coupler half —
##                      follows Runner's angle every frame
##   Machine/GenSpin    the driven pulley / gear, the generator shaft — turns
##                      at the drive's ratio (reversed for gears)
##   Machine/Housing, Machine/Window, Machine/Static, Machine/Jets
## Spinning parts carry skip_prop_collision; the housing, base, bearings and
## generator are the placed prop's collision.

const MODEL_ID := "peltonlab_turbine"

var _d: Dictionary = {}
var _machine: Node3D = null
var _runner: Node3D = null
var _shaft_spin: Node3D = null
var _gen_spin: Node3D = null
var _housing_mi: MeshInstance3D = null
var _window_mi: MeshInstance3D = null
var _jets_mi: MeshInstance3D = null
var _gen_phase := 0.0
var _ratio := 1.0
var _reverse := false
var _spin_rpm := -1.0
var _spin_angle := 0.0
var _ghost := false
var _nozzles_on := true
var _picks: Array = []

static var _mats: Dictionary = {}


static func build_node(spec: Dictionary = {}, node_name: String = "PeltonTurbine", opts: Dictionary = {}) -> Node3D:
	return build_from_design(PeltonLabDesign.solve(spec), node_name, opts)


static func build_from_design(d: Dictionary, node_name: String = "PeltonTurbine", opts: Dictionary = {}) -> Node3D:
	var b := PeltonLabBuilder.new()
	b.name = node_name
	b._ghost = bool(opts.get("ghost_highlight", false))
	b._nozzles_on = bool(opts.get("nozzles", true))
	b._build(d)
	b.set_meta("pelton_spec", PeltonLabSpec.to_json_safe(d["spec"]))
	b.set_housing_view(str(opts.get("housing_view", "window")))
	return b


func design() -> Dictionary:
	return _d


func runner() -> Node3D:
	return _runner


func gen_ratio() -> float:
	return _ratio


## The studio spins the runner itself (rpm < 0 hands it back to whoever
## turns the Runner node — the world's SiphonTurbineSpin).
func set_spin_rpm(rpm: float) -> void:
	_spin_rpm = rpm


## "solid" | "window" (the clear front panel) | "cut" (front wall off) |
## "ghost" (every wall see-through) | "hidden".
func set_housing_view(mode: String) -> void:
	if _housing_mi == null:
		return
	_housing_mi.visible = mode != "hidden"
	if _window_mi != null:
		_window_mi.visible = mode in ["solid", "window", "ghost"]
		# The front wall is clear only when the design has a window; "solid"
		# shows it as plate whatever the design says.
		_window_mi.material_override = _material("housing", true) if mode == "solid" else (
				null if mode == "window" else _material("ghost", false))
	_housing_mi.material_override = _material("ghost", false) if mode == "ghost" else null


func set_show_jets(on: bool) -> void:
	if _jets_mi != null:
		_jets_mi.visible = on


func _process(delta: float) -> void:
	if _runner == null:
		return
	if _spin_rpm >= 0.0:
		_spin_angle = fposmod(_spin_angle + _spin_rpm * TAU / 60.0 * delta, TAU)
		_runner.transform = Transform3D(Basis(Vector3.RIGHT, _spin_angle), Vector3.ZERO)
	var v := _runner.transform.basis * Vector3.UP
	var a := atan2(v.z, v.y)
	if _shaft_spin != null:
		_shaft_spin.transform.basis = Basis(Vector3.RIGHT, a)
	if _gen_spin != null:
		_gen_spin.transform.basis = Basis(Vector3.RIGHT, _gen_phase + a * _ratio * (-1.0 if _reverse else 1.0))


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build(d: Dictionary) -> void:
	_d = d
	var s: Dictionary = d["spec"]
	_machine = Node3D.new()
	_machine.name = "Machine"
	_machine.transform = d["model_xf"]
	add_child(_machine)
	# --- Runner: cups + rotor.
	_runner = Node3D.new()
	_runner.name = "Runner"
	_machine.add_child(_runner)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = PeltonLabCup.mesh()
	var xfs: Array = d["runner"]["cup_xfs"]
	mm.instance_count = xfs.size()
	var rb := Transform3D(PeltonLabDesign.runner_basis(), Vector3.ZERO)
	var rn: Dictionary = d["runner"]
	var cup_box := AABB()
	for i in xfs.size():
		mm.set_instance_transform(i, rb * (xfs[i] as Transform3D))
	var cups := MultiMeshInstance3D.new()
	cups.name = "Cups"
	cups.multimesh = mm
	cups.material_override = _material("cup:" + str(s["runner"]["cup_material"]), false, s["colors"]["cup"])
	var tip := float(rn["tip_r_mm"]) * 0.001
	var half_w := float(rn["cup_w_mm"]) * 0.0006
	cup_box = AABB(Vector3(-half_w, -tip, -tip), Vector3(half_w * 2.0, tip * 2.0, tip * 2.0))
	mm.custom_aabb = cup_box
	_runner.add_child(cups)
	_pick("Cups", cup_box)
	var rsts := {}
	_rotor(rsts, d)
	_runner.add_child(_commit(rsts, "RotorMesh", true))
	# --- Shaft (follows the runner) and the generator's spinning half.
	_shaft_spin = Node3D.new()
	_shaft_spin.name = "ShaftSpin"
	_machine.add_child(_shaft_spin)
	var ssts := {}
	_shaft(ssts, d)
	var gsts := {}
	var static_sts := {}
	_drive(ssts, gsts, static_sts, d)
	_shaft_spin.add_child(_commit(ssts, "ShaftMesh", true))
	var gen: Dictionary = d["generator"]
	_gen_spin = Node3D.new()
	_gen_spin.name = "GenSpin"
	_gen_spin.position = gen["axis"]
	_machine.add_child(_gen_spin)
	_gen_spin.add_child(_commit(gsts, "GenSpinMesh", true))
	_ratio = float(d["drive"]["ratio"])
	_reverse = bool(d["drive"]["reverses"])
	# --- Static: bearings, generator body, nozzles, base.
	_bearings(static_sts, d)
	_generator(static_sts, d)
	if _nozzles_on:
		_nozzles(static_sts, d)
	_base(static_sts, d)
	_machine.add_child(_commit(static_sts, "Static", false))
	# --- Housing and its window.
	var hsts := {}
	var wsts := {}
	_housing(hsts, wsts, d)
	_housing_mi = _commit(hsts, "Housing", false)
	_machine.add_child(_housing_mi)
	_window_mi = _commit(wsts, "Window", true)
	_machine.add_child(_window_mi)
	# --- The jets (shown in the studio).
	var jsts := {}
	for j in d["jets"]:
		var mouth: Vector3 = j["mouth"]
		var dir: Vector3 = j["dir"]
		_at(Transform3D.IDENTITY)
		GantryLabDetail.cyl(_st(jsts, "jet"), mouth, (j["hit"] as Vector3) + dir * float(j["d_mm"]) * 0.0006,
				float(j["d_mm"]) * 0.0005, 14)
	_jets_mi = _commit(jsts, "Jets", true)
	_jets_mi.visible = false
	_machine.add_child(_jets_mi)
	set_meta("pelton_picks", _picks)


# ---------------------------------------------------------------------------
# Rotor: two discs, the spacer ring, the hub, every bolt
# ---------------------------------------------------------------------------

func _rotor(sts: Dictionary, d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var ro: Dictionary = d["rotor"]
	var rn: Dictionary = d["runner"]
	var mm := 0.001
	var shaft_r := float(ro["shaft_d_mm"]) * 0.5 * mm
	var disc_r := float(ro["disc_r_mm"]) * mm
	var t := float(ro["disc_t_mm"]) * mm
	var gap := float(ro["gap_mm"]) * mm
	var sides := 72
	for xc in [float(ro["x_disc_a_mm"]) * mm, float(ro["x_disc_b_mm"]) * mm]:
		_ring_x(_st(sts, "disc"), float(xc) - t * 0.5, float(xc) + t * 0.5, shaft_r, disc_r, sides)
	_ring_x(_st(sts, "disc"), -gap * 0.5, gap * 0.5, shaft_r + 0.001, float(ro["spacer_r_mm"]) * mm, sides)
	_ring_x(_st(sts, "steel"), float(ro["x_flange0_mm"]) * mm, float(ro["x_flange1_mm"]) * mm, shaft_r,
		float(ro["flange_d_mm"]) * 0.5 * mm, 48)
	_ring_x(_st(sts, "steel"), float(ro["x_flange1_mm"]) * mm, float(ro["x_boss1_mm"]) * mm, shaft_r,
		float(ro["boss_d_mm"]) * 0.5 * mm, 32)
	_pick("Rotor discs and hub", AABB(Vector3(float(ro["x_min_mm"]) * mm, -disc_r, -disc_r),
		Vector3((float(ro["x_boss1_mm"]) - float(ro["x_min_mm"])) * mm, disc_r * 2.0, disc_r * 2.0)))
	# Cup bolts: axial through disc, tab, disc; head on −X, nyloc on +X.
	var cb := PeltonLabParts.bolt(str(s["runner"]["cup_bolt"]))
	var x0 := float(ro["x_disc_a_mm"]) * mm - t * 0.5
	var x1 := float(ro["x_disc_b_mm"]) * mm + t * 0.5
	var rb := PeltonLabDesign.runner_basis()
	for p in rn["cup_bolts"]:
		var c := rb * (p as Vector3)
		_bolt_x(sts, x0, x1, c.y, c.z, cb)
	# Hub bolts: through disc, spacer, disc and the hub flange.
	var hb := PeltonLabParts.bolt(str(s["hub"]["bolt"]))
	var n := int(s["hub"]["bolts"])
	var pr := float(ro["bolt_pcd_mm"]) * 0.5 * mm
	for i in n:
		var a := TAU * (float(i) + 0.5) / float(n)
		_bolt_x(sts, x0, float(ro["x_flange1_mm"]) * mm, cos(a) * pr, sin(a) * pr, hb)


## An annulus along X from x0 to x1 (radii ri < ro), centred on the X axis.
func _ring_x(st: SurfaceTool, x0: float, x1: float, ri: float, ro: float, sides: int) -> void:
	_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3.ZERO))
	GantryLabDetail.lathe(st, PackedVector2Array([Vector2(ri, x0), Vector2(ro, x0), Vector2(ro, x1),
		Vector2(ri, x1), Vector2(ri, x0)]), sides)
	_at(Transform3D.IDENTITY)


## An annulus along X centred at (y, z).
func _ring_x_at(st: SurfaceTool, x0: float, x1: float, ri: float, ro: float, y: float, z: float, sides: int) -> void:
	_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3(0.0, y, z)))
	var prof := PackedVector2Array([Vector2(ri, x0), Vector2(ro, x0), Vector2(ro, x1), Vector2(ri, x1), Vector2(ri, x0)])
	if ri <= 0.0:
		prof = PackedVector2Array([Vector2(0.0, x0), Vector2(ro, x0), Vector2(ro, x1), Vector2(0.0, x1)])
	GantryLabDetail.lathe(st, prof, sides)
	_at(Transform3D.IDENTITY)


## A bolt along X at (y, z): hex head before x0, washer-faced nyloc after x1.
func _bolt_x(sts: Dictionary, x0: float, x1: float, y: float, z: float, b: Dictionary) -> void:
	var d := float(b["d"]) * 0.001
	var af := float(b["af"]) * 0.001
	var head_h := d * 0.7
	var nut_h := d * 1.0
	_at(Transform3D.IDENTITY)
	GantryLabDetail.cyl(_st(sts, "chrome"), Vector3(x0 - head_h, y, z), Vector3(x1 + nut_h + d * 0.6, y, z), d * 0.5, 8)
	for spec in [[x0 - head_h, x0], [x1, x1 + nut_h]]:
		_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3(0.0, y, z)))
		GantryLabDetail.prism(_st(sts, "chrome"), GantryLabDetail.ngon_outline(af * 0.577, 6, PI / 6.0),
			float(spec[0]), float(spec[1]))
	_at(Transform3D.IDENTITY)


# ---------------------------------------------------------------------------
# Shaft and drive
# ---------------------------------------------------------------------------

func _shaft(sts: Dictionary, d: Dictionary) -> void:
	var sh: Dictionary = d["shaft"]
	var r := float(sh["d_mm"]) * 0.0005
	var x0 := float(sh["x0_mm"]) * 0.001
	var x1 := float(sh["x1_mm"]) * 0.001
	_at(Transform3D.IDENTITY)
	GantryLabDetail.cyl(_st(sts, "chrome"), Vector3(x0, 0, 0), Vector3(x1, 0, 0), r, 20)
	if bool(sh["key"]):
		var ro: Dictionary = d["rotor"]
		var kx0 := float(ro["x_flange0_mm"]) * 0.001
		var kx1 := float(ro["x_boss1_mm"]) * 0.001
		GantryLabDetail.box_ab(_st(sts, "steel"), Vector3(kx0, r * 0.75, -r * 0.25), Vector3(kx1, r * 1.15, r * 0.25))
	_pick("Shaft (Ø %.0f mm)" % float(sh["d_mm"]), AABB(Vector3(x0, -r, -r), Vector3(x1 - x0, 2.0 * r, 2.0 * r)))


func _drive(ssts: Dictionary, gsts: Dictionary, static_sts: Dictionary, d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var dv: Dictionary = d["drive"]
	var gen: Dictionary = d["generator"]
	var ga: Vector3 = gen["axis"]
	var shaft_r := float(d["shaft"]["d_mm"]) * 0.0005
	var gshaft_r := float(gen["spec"]["shaft_mm"]) * 0.0005
	var mm := 0.001
	var face := float(gen["face_x_mm"]) * mm
	match str(dv["type"]):
		"direct":
			var c: Dictionary = dv["coupler"]
			var cx0 := float(c["x0_mm"]) * mm
			var clen := float(c["len_mm"]) * mm
			var cr := float(c["od_mm"]) * 0.5 * mm
			if str(s["drive"]["coupler"]) == "jaw":
				_ring_x_at(_st(ssts, "alu"), cx0, cx0 + clen * 0.42, shaft_r, cr, 0, 0, 24)
				_ring_x_at(_st(ssts, "rubber_red"), cx0 + clen * 0.42, cx0 + clen * 0.58, 0.0, cr * 0.92, 0, 0, 12)
				# The generator's half, in GenSpin's frame (origin = the generator axis at its face).
				_ring_x_at(_st(gsts, "alu"), cx0 + clen * 0.58 - face, cx0 + clen - face, gshaft_r, cr, 0, 0, 24)
			else:
				_ring_x_at(_st(ssts, "alu"), cx0, cx0 + clen, shaft_r, cr, 0, 0, 24)
			_at(Transform3D.IDENTITY)
			GantryLabDetail.cyl(_st(gsts, "chrome"), Vector3(cx0 + clen * 0.6 - face, 0, 0), Vector3(0.005, 0, 0), gshaft_r, 12)
			_pick("Coupler (%s)" % str(c["size"]), AABB(Vector3(cx0, -cr, -cr), Vector3(clen, 2.0 * cr, 2.0 * cr)))
		"vbelt", "timing", "gear":
			var t := str(dv["type"])
			var xp := float(dv["x_pulley_mm"]) * mm
			var w := float(dv["w_mm"]) * mm
			var r1 := float(dv["d1_mm"]) * 0.5 * mm
			var r2 := float(dv["d2_mm"]) * 0.5 * mm
			var gx := xp - face   # the pulley plane in GenSpin's frame
			if t == "vbelt":
				_vpulley(_st(ssts, "cast"), xp, w, r1, shaft_r, Vector2.ZERO)
				_vpulley(_st(gsts, "cast"), gx, w, r2, gshaft_r, Vector2.ZERO)
			elif t == "timing":
				_tpulley(ssts, xp, w, int(s["drive"]["driver_teeth"]), shaft_r)
				_tpulley(gsts, gx, w, int(s["drive"]["driven_teeth"]), gshaft_r)
			else:
				var mod := float(s["drive"]["module_mm"]) * mm
				_gear(_st(ssts, "steel"), xp, w, int(s["drive"]["driver_teeth"]), mod, shaft_r)
				_gear(_st(gsts, "brass"), gx, w, int(s["drive"]["driven_teeth"]), mod, gshaft_r)
				# Mesh the teeth: a gap of the driven gear faces the driver.
				var toward := Vector2(-ga.y, -ga.z).normalized()
				var ang := atan2(toward.y, toward.x)
				_gen_phase = -ang + PI / float(int(s["drive"]["driven_teeth"]))
			_at(Transform3D.IDENTITY)
			GantryLabDetail.cyl(_st(gsts, "chrome"), Vector3(gx - w * 0.6, 0, 0), Vector3(0.005, 0, 0), gshaft_r, 12)
			if t != "gear":
				var loop := belt_loop(Vector2.ZERO, r1, Vector2(ga.y, ga.z), r2)
				var pts := PackedVector3Array()
				for q in loop:
					pts.append(Vector3(xp + w * 0.5, (q as Vector2).x, (q as Vector2).y))
				pts.append(pts[0])
				_at(Transform3D.IDENTITY)
				if t == "vbelt":
					GantryLabDetail.tube(_st(static_sts, "belt"), pts, 0.0055, 6)
				else:
					GantryLabDetail.ribbon(_st(static_sts, "belt"), pts, Vector3.RIGHT, w * 0.8, 0.0035, 1.0)
			var lo := Vector3(xp, minf(-r1, ga.y - r2), minf(-r1, ga.z - r2))
			var hi := Vector3(xp + w, maxf(r1, ga.y + r2), maxf(r1, ga.z + r2))
			_pick(str(PeltonLabParts.DRIVES[t]["label"]) + " %.2f : 1" % float(dv["ratio"]), AABB(lo, hi - lo))


## The points of an open belt round two pulleys (centres a, b in the belt's
## plane, radii ra, rb): the external tangents and the arcs on each pulley's
## far side. Counter-clockwise, not closed.
static func belt_loop(a: Vector2, ra: float, b: Vector2, rb: float, seg: int = 24) -> Array:
	var ab := b - a
	var c := ab.length()
	if c < 1e-6:
		return []
	var u := ab / c
	var v := Vector2(-u.y, u.x)
	var phi := asin(clampf((ra - rb) / c, -1.0, 1.0))
	var out: Array = []
	var a0 := PI * 0.5 + phi
	var a1 := PI * 1.5 - phi
	for i in seg + 1:
		var th := lerpf(a0, a1, float(i) / float(seg))
		out.append(a + (u * cos(th) + v * sin(th)) * ra)
	var b0 := -PI * 0.5 - phi
	var b1 := PI * 0.5 + phi
	for i in seg + 1:
		var th := lerpf(b0, b1, float(i) / float(seg))
		out.append(b + (u * cos(th) + v * sin(th)) * rb)
	return out


## A V-belt pulley along X at x0 (width w): rims, the A-section groove at the
## pitch radius, the hub on the bore.
func _vpulley(st: SurfaceTool, x0: float, w: float, rp: float, bore_r: float, _c: Vector2) -> void:
	var ro := rp + 0.004
	var rg := maxf(rp - 0.008, bore_r + 0.006)
	var hub := minf(bore_r * 2.2, rg)
	_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3.ZERO))
	GantryLabDetail.lathe(st, PackedVector2Array([Vector2(bore_r, x0), Vector2(ro, x0), Vector2(ro, x0 + w * 0.12),
		Vector2(rg, x0 + w * 0.5), Vector2(ro, x0 + w * 0.88), Vector2(ro, x0 + w), Vector2(bore_r, x0 + w), Vector2(bore_r, x0)]), 40)
	GantryLabDetail.lathe(st, PackedVector2Array([Vector2(bore_r, x0 - w * 0.3), Vector2(hub, x0 - w * 0.3),
		Vector2(hub, x0), Vector2(bore_r, x0), Vector2(bore_r, x0 - w * 0.3)]), 20)
	_at(Transform3D.IDENTITY)


func _tpulley(sts: Dictionary, x0: float, w: float, teeth: int, bore_r: float) -> void:
	var rp := PeltonLabParts.timing_pitch_d_mm(teeth) * 0.0005
	var r := rp - 0.0006
	var outline := PackedVector2Array()
	for i in teeth:
		var a0 := TAU * float(i) / float(teeth)
		var a1 := TAU * (float(i) + 0.55) / float(teeth)
		var rr := r - 0.0021
		outline.append(Vector2(cos(a0) * rr, sin(a0) * rr))
		outline.append(Vector2(cos(a0 + 0.1 / teeth * TAU) * r, sin(a0 + 0.1 / teeth * TAU) * r))
		outline.append(Vector2(cos(a1) * r, sin(a1) * r))
		outline.append(Vector2(cos(a1 + 0.1 / teeth * TAU) * rr, sin(a1 + 0.1 / teeth * TAU) * rr))
	_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3.ZERO))
	GantryLabDetail.prism(_st(sts, "alu"), outline, x0 + 0.002, x0 + w - 0.002, true)
	GantryLabDetail.lathe(_st(sts, "alu"), PackedVector2Array([Vector2(bore_r, x0), Vector2(rp + 0.004, x0),
		Vector2(rp + 0.004, x0 + 0.002), Vector2(bore_r, x0 + 0.002), Vector2(bore_r, x0)]), 36)
	GantryLabDetail.lathe(_st(sts, "alu"), PackedVector2Array([Vector2(bore_r, x0 + w - 0.002), Vector2(rp + 0.004, x0 + w - 0.002),
		Vector2(rp + 0.004, x0 + w), Vector2(bore_r, x0 + w), Vector2(bore_r, x0 + w - 0.002)]), 36)
	_at(Transform3D.IDENTITY)


func _gear(st: SurfaceTool, x0: float, w: float, teeth: int, mod: float, bore_r: float) -> void:
	var rp := float(teeth) * mod * 0.5
	var ra := rp + mod
	var rf := maxf(rp - 1.25 * mod, bore_r + 0.003)
	var outline := PackedVector2Array()
	for i in teeth:
		var c := TAU * float(i) / float(teeth)
		var p := TAU / float(teeth)
		outline.append(Vector2(cos(c - p * 0.30), sin(c - p * 0.30)) * rf)
		outline.append(Vector2(cos(c - p * 0.18), sin(c - p * 0.18)) * ra)
		outline.append(Vector2(cos(c + p * 0.18), sin(c + p * 0.18)) * ra)
		outline.append(Vector2(cos(c + p * 0.30), sin(c + p * 0.30)) * rf)
	_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3.ZERO))
	GantryLabDetail.prism(st, outline, x0, x0 + w, true)
	_at(Transform3D.IDENTITY)


# ---------------------------------------------------------------------------
# Bearings, generator, nozzles, base, housing
# ---------------------------------------------------------------------------

func _bearings(sts: Dictionary, d: Dictionary) -> void:
	var sh: Dictionary = d["shaft"]
	var br: Dictionary = sh["bearing"]
	var mm := 0.001
	var shaft_r := float(sh["d_mm"]) * 0.5 * mm
	for bx in sh["bearings_x_mm"]:
		var x := float(bx) * mm
		if bool(sh["flange"]):
			var fl := float(br["fL"]) * mm
			var fa := float(br["fA"]) * mm
			var fb := float(br["fB"]) * 0.5 * mm
			# Two-bolt diamond flange (in the YZ plane), the housing boss, the
			# insert's collar.
			var outline := PackedVector2Array([Vector2(0, -fl * 0.5), Vector2(fb, -fl * 0.25), Vector2(fb, fl * 0.25),
				Vector2(0, fl * 0.5), Vector2(-fb, fl * 0.25), Vector2(-fb, -fl * 0.25)])
			_at(Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3(x, 0, 0)))
			GantryLabDetail.prism(_st(sts, "cast"), outline, -fa * 0.5, -fa * 0.5 + 0.012)
			_at(Transform3D.IDENTITY)
			_ring_x(_st(sts, "cast"), x - fa * 0.5, x + fa * 0.5, shaft_r + 0.004, fb * 0.95, 28)
			for sy in [-1.0, 1.0]:
				_bolt_x(sts, x - fa * 0.5 - 0.004, x - fa * 0.5 + 0.012, 0.0, sy * float(br["fJ"]) * 0.5 * mm, PeltonLabParts.bolt("m10"))
			_pick("Flange bearing %s" % str(br["flange"]), AABB(Vector3(x - fa * 0.5, -fb, -fl * 0.5), Vector3(fa, 2.0 * fb, fl)))
		else:
			var h := float(br["H"]) * mm
			var ht := float(br["Ht"]) * mm
			var l := float(br["L"]) * mm
			var a := float(br["A"]) * mm
			var top := ht - h
			# Base foot (along Z, across the shaft), the web, the round housing.
			GantryLabDetail.box_ab(_st(sts, "cast"), Vector3(x - a * 0.5, -h, -l * 0.5), Vector3(x + a * 0.5, -h + 0.016, l * 0.5))
			GantryLabDetail.box_ab(_st(sts, "cast"), Vector3(x - a * 0.35, -h + 0.016, -top * 0.9), Vector3(x + a * 0.35, 0.0, top * 0.9))
			_ring_x(_st(sts, "cast"), x - a * 0.4, x + a * 0.4, shaft_r + 0.004, top, 28)
			_ring_x(_st(sts, "chrome"), x - a * 0.5, x + a * 0.5, shaft_r, shaft_r + 0.005, 20)
			for sz in [-1.0, 1.0]:
				_at(Transform3D.IDENTITY)
				GantryLabDetail.cyl(_st(sts, "chrome"), Vector3(x, -h - 0.004, sz * float(br["J"]) * 0.5 * mm),
					Vector3(x, -h + 0.026, sz * float(br["J"]) * 0.5 * mm), 0.006, 6)
			_pick("Pillow block %s" % str(br["pillow"]), AABB(Vector3(x - a * 0.5, -h, -l * 0.5), Vector3(a, ht, l)))


func _generator(sts: Dictionary, d: Dictionary) -> void:
	var gen: Dictionary = d["generator"]
	var g: Dictionary = gen["spec"]
	var ga: Vector3 = gen["axis"]
	var face := float(gen["face_x_mm"]) * 0.001
	var glen := float(gen["len_mm"]) * 0.001
	var c := Vector3(face, ga.y, ga.z)
	match str(g["body"]):
		"nema":
			GantryLabDetail.emit(sts, {"kind": "motor", "c": c, "basis": GantryLabDetail.basis_y(-Vector3.RIGHT),
				"frame": float(g["frame_mm"]) * 0.001, "len": glen, "shaft": 0.002})
			var f := float(g["frame_mm"]) * 0.001
			_pick(str(g["label"]), AABB(c - Vector3(0, f * 0.5, f * 0.5), Vector3(glen, f, f)))
		"can", "alternator":
			var r := float(g["dia_mm"]) * 0.0005
			var alt := str(g["body"]) == "alternator"
			_ring_x_at(_st(sts, "gen"), face, face + glen, 0.0, r, ga.y, ga.z, 36)
			# Cooling fins / the alternator's vents.
			for i in 5:
				var fx := face + glen * (0.2 + 0.15 * float(i))
				_ring_x_at(_st(sts, "alu" if alt else "gen"), fx, fx + 0.004, r * 0.98, r * 1.04, ga.y, ga.z, 36)
			# The front mounting flange and, for an alternator, its fan.
			_ring_x_at(_st(sts, "alu"), face, face + 0.008, 0.0, r * (0.85 if alt else 1.08), ga.y, ga.z, 36)
			# Terminal box on the back.
			_at(Transform3D.IDENTITY)
			GantryLabDetail.box_ab(_st(sts, "black"), Vector3(face + glen - 0.002, ga.y - 0.02, ga.z - 0.03),
				Vector3(face + glen + 0.025, ga.y + 0.02, ga.z + 0.03))
			_pick(str(g["label"]), AABB(c - Vector3(0, r, r), Vector3(glen, 2.0 * r, 2.0 * r)))


func _nozzles(sts: Dictionary, d: Dictionary) -> void:
	for j in d["jets"]:
		var jd := float(j["d_mm"]) * 0.001
		var mouth: Vector3 = j["mouth"]
		var dir: Vector3 = j["dir"]
		var inlet: Vector3 = j["inlet"]
		var pipe_r := maxf(jd * 1.25, 0.012)
		var cone_len := maxf(jd * 2.5, 0.03)
		var cone0 := mouth - dir * cone_len
		_at(Transform3D.IDENTITY)
		if (cone0 - inlet).dot(dir) > 0.0:
			GantryLabDetail.cyl(_st(sts, "steel"), inlet, cone0, pipe_r, 18)
		_at(Transform3D(GantryLabDetail.basis_y(dir), cone0))
		GantryLabDetail.lathe(_st(sts, "brass"), PackedVector2Array([Vector2(0.0, 0.0), Vector2(pipe_r, 0.0),
			Vector2(jd * 0.5 + 0.002, cone_len), Vector2(jd * 0.5, cone_len), Vector2(0.0, cone_len)]), 18)
		# The inlet flange outside the housing and the spear valve's stem.
		_at(Transform3D(GantryLabDetail.basis_y(dir), inlet))
		GantryLabDetail.cyl_y(_st(sts, "steel"), 0.0, 0.01, pipe_r * 1.9, 18)
		_at(Transform3D.IDENTITY)
		GantryLabDetail.cyl(_st(sts, "chrome"), inlet - dir * 0.08, inlet, jd * 0.25, 8)
		GantryLabDetail.box(_st(sts, "red"), inlet - dir * 0.085, Vector3.ONE * pipe_r * 1.6)
		var lo := Vector3(minf(inlet.x, mouth.x), minf(inlet.y, mouth.y), minf(inlet.z, mouth.z)) - Vector3.ONE * pipe_r
		var hi := Vector3(maxf(inlet.x, mouth.x), maxf(inlet.y, mouth.y), maxf(inlet.z, mouth.z)) + Vector3.ONE * pipe_r
		_pick("Nozzle (%.0f mm jet)" % float(j["d_mm"]), AABB(lo, hi - lo))


func _base(sts: Dictionary, d: Dictionary) -> void:
	var b: Dictionary = d["base"]
	_at(Transform3D.IDENTITY)
	for r in b["boxes"]:
		var a: Vector3 = r["a"]
		var c: Vector3 = r["b"]
		var lo := Vector3(minf(a.x, c.x), minf(a.y, c.y), minf(a.z, c.z))
		var hi := Vector3(maxf(a.x, c.x), maxf(a.y, c.y), maxf(a.z, c.z))
		if (hi - lo).x < 1e-4 or (hi - lo).y < 1e-4 or (hi - lo).z < 1e-4:
			continue
		GantryLabDetail.box_ab(_st(sts, "frame"), lo, hi)
	if not (b["boxes"] as Array).is_empty():
		var all: Array = b["boxes"]
		var lo: Vector3 = all[0]["a"]
		var hi: Vector3 = all[0]["b"]
		for r in all:
			for p in [r["a"], r["b"]]:
				lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
				hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
		_pick("Base frame", AABB(lo, hi - lo))


func _housing(hsts: Dictionary, wsts: Dictionary, d: Dictionary) -> void:
	var h: Dictionary = d["housing"]
	var mm := 0.001
	var hx := float(h["axial_mm"]) * 0.5 * mm
	var hy := float(h["hy_mm"]) * mm
	var hz := float(h["hz_mm"]) * mm
	var t := float(h["wall_mm"]) * mm
	var open := str(h["open"])
	var walls := {
		"+x": [Vector3(hx, -hy, -hz), Vector3(hx + t, hy, hz)],
		"-x": [Vector3(-hx - t, -hy, -hz), Vector3(-hx, hy, hz)],
		"+y": [Vector3(-hx - t, hy, -hz - t), Vector3(hx + t, hy + t, hz + t)],
		"-y": [Vector3(-hx - t, -hy - t, -hz - t), Vector3(hx + t, -hy, hz + t)],
		"+z": [Vector3(-hx - t, -hy, hz), Vector3(hx + t, hy, hz + t)],
		"-z": [Vector3(-hx - t, -hy, -hz - t), Vector3(hx + t, hy, -hz)],
	}
	_at(Transform3D.IDENTITY)
	for k in walls:
		if k == open:
			continue
		var w: Array = walls[k]
		var st := _st(hsts, "housing")
		if k == "-z":
			st = _st(wsts, "acrylic" if bool(h["window"]) else "housing")
		GantryLabDetail.box_ab(st, w[0], w[1])
	_pick("Housing", AABB(Vector3(-hx - t, -hy - t, -hz - t), Vector3(2.0 * (hx + t), 2.0 * (hy + t), 2.0 * (hz + t))))


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

static func _at(xf: Transform3D) -> void:
	GantryLabDetail._xf = xf


static func _st(sts: Dictionary, key: String) -> SurfaceTool:
	return GantryLabDetail._st(sts, key)


func _pick(label: String, box: AABB) -> void:
	_picks.append({"label": label, "aabb": box})


func _commit(sts: Dictionary, node_name: String, skip_collision: bool) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var keys: Array = sts.keys()
	keys.sort()
	var cols: Dictionary = _d["spec"]["colors"]
	for key in keys:
		var st: SurfaceTool = sts[key]
		var arrays := st.commit_to_arrays()
		if arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(str(key), false, cols.get(str(key), null)))
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	if skip_collision:
		mi.set_meta("skip_prop_collision", true)
	return mi


func _material(key: String, alt: bool, tint: Variant = null) -> Material:
	var cols: Dictionary = _d["spec"]["colors"] if not _d.is_empty() else {}
	var col_key := key
	if key.begins_with("cup:"):
		col_key = "cup"
	var c: Variant = tint if tint != null else cols.get(col_key, null)
	var ck := "%s|%s|%s|%s|%s" % [key, str(alt), str(c), str(cols.get("housing", "")), "g" if _ghost else "s"]
	if _mats.has(ck):
		return _mats[ck]
	var m := _make_material(key, alt, cols)
	if _ghost and m is StandardMaterial3D:
		var sm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color = Color(sm.albedo_color.r, sm.albedo_color.g, sm.albedo_color.b, 0.55)
		sm.emission_enabled = true
		sm.emission = Color(0.2, 0.7, 0.9) * 0.25
		m = sm
	_mats[ck] = m
	return m


static func _plain(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	return m


func _make_material(key: String, alt: bool, cols: Dictionary) -> Material:
	if key.begins_with("cup:"):
		var cm := key.substr(4)
		match cm:
			"alu_cast":
				return _plain(Color(0.78, 0.79, 0.8), 0.8, 0.45)
			"bronze":
				return _plain(Color(0.78, 0.55, 0.28), 0.9, 0.35)
			"stainless":
				return _plain(Color(0.82, 0.83, 0.85), 0.9, 0.3)
			"nylon":
				return _plain(Color(0.92, 0.91, 0.86), 0.0, 0.55)
		return _plain(cols.get("cup", Color(0.78, 0.62, 0.32)), 0.0, 0.5)
	match key:
		"disc":
			var dm := str(_d["spec"]["rotor"]["material"])
			match dm:
				"alu":
					return _plain(Color(0.8, 0.81, 0.83), 0.8, 0.4)
				"stainless":
					return _plain(Color(0.8, 0.81, 0.83), 0.9, 0.3)
				"hdpe":
					return _plain(Color(0.15, 0.15, 0.16), 0.0, 0.7)
				"plywood":
					return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.65, 0.52, 0.36))
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("disc", Color(0.36, 0.38, 0.42)))
		"housing":
			var hm := str(_d["spec"]["housing"]["material"])
			match hm:
				"stainless":
					return _plain(Color(0.78, 0.79, 0.81), 0.85, 0.35)
				"alu":
					return _plain(Color(0.8, 0.81, 0.83), 0.8, 0.4)
				"hdpe":
					return _plain(Color(0.12, 0.12, 0.13), 0.0, 0.7)
				"plywood":
					return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.62, 0.5, 0.36))
				"acrylic":
					return _clear()
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("housing", Color(0.22, 0.42, 0.58)))
		"acrylic":
			return _clear()
		"ghost":
			var g := _plain(Color(0.55, 0.7, 0.8, 0.16), 0.0, 0.3)
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			g.cull_mode = BaseMaterial3D.CULL_DISABLED
			return g
		"frame":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("frame", Color(0.18, 0.19, 0.21)))
		"gen", "motor":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, cols.get("generator", Color(0.12, 0.13, 0.15)))
		"cast":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.27, 0.33, 0.38))
		"alu":
			return _plain(Color(0.8, 0.81, 0.83), 0.85, 0.35)
		"chrome":
			return _plain(Color(0.84, 0.85, 0.87), 0.95, 0.2)
		"steel":
			return _plain(Color(0.3, 0.31, 0.33), 0.75, 0.45)
		"brass":
			return _plain(Color(0.82, 0.64, 0.3), 0.9, 0.35)
		"black":
			return StructureMaterials.make(StructureMaterials.Kind.PLASTIC, Color(0.08, 0.08, 0.09))
		"belt", "rubber":
			return _plain(Color(0.06, 0.06, 0.06), 0.0, 0.9)
		"rubber_red", "red":
			return _plain(Color(0.75, 0.12, 0.1), 0.0, 0.7)
		"jet":
			var j := _plain(Color(0.65, 0.85, 1.0, 0.6), 0.0, 0.1)
			j.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			j.emission_enabled = true
			j.emission = Color(0.3, 0.55, 0.8) * 0.4
			return j
	return _plain(Color(0.5, 0.5, 0.5), 0.0, 0.7)


static func _clear() -> StandardMaterial3D:
	var a := _plain(Color(0.8, 0.9, 0.95, 0.22), 0.0, 0.05)
	a.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	a.cull_mode = BaseMaterial3D.CULL_DISABLED
	return a


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## The part under a ray (world space): {label, distance} or {}.
static func pick(node: Node3D, origin: Vector3, dir: Vector3) -> Dictionary:
	if node == null or not node.has_meta("pelton_picks"):
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
	for p in node.get_meta("pelton_picks"):
		var box: AABB = p["aabb"]
		var hit: Variant = box.intersects_ray(o, dv)
		if hit == null:
			continue
		var t := (hit as Vector3).distance_to(o)
		# Small parts first: a bolt or a bearing inside the housing's box wins.
		var size := box.size.length()
		var score := t + size * 0.25
		if score < best_t:
			best_t = score
			best = {"label": str(p["label"]), "distance": t}
	return best

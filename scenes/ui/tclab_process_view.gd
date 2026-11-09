extends Node3D

## What happens inside a tri-clamp assembly while the TC Process Lab runs it
## (Phase 4 of plans/TC_PROCESS_LAB_PLAN.md). A sibling of the designer's
## TcBuilder under the studio holder (the same frame: assembly metres), made
## by tclab_process_panel.gd while Process mode is up.
##
## Three ways to look:
##   solid    the parts as built, tinted by temperature (the panel's overlay)
##   section  every part cut by one plane (tc_section.gdshader: the far side
##            discarded, the cut faces painted solid), contents drawn inside
##   xray     every part a see-through ghost (tc_xray.gdshader), contents
##            drawn whole
## The contents are read off the running TcProcSim every frame:
##   gas      a tube along each volume's centre line (tc_gas.gdshader):
##            colour from what is in it, thickness from how much is not air,
##            drifting the way it flows at a speed that follows the gas's
##   liquid   the same tube below the liquid's level (tc_liquid.gdshader)
##   charge   a cylinder whose cut face is the bed's real cross-section
##            (tc_bed.gdshader reads the cells): wet, dry, the pyrolysis
##            front, glowing char, the elements' glow
##   vapour   a few pooled particle emitters: vapour rising off the charge,
##            the plume at the gas outlet, drips where it condenses,
##            bubbles in a boiling pool. The vapour in the vessel is drawn
##            by tc_smoke.gdshader, which cuts every puff off at the
##            vessel's inside wall and lid: the gas is contained.
## Process units move with the run (always drawn, whatever the look): a
## gasometer's float stands where its gas has it (the built part's float is
## hidden while this view is up and a live one drawn at fill × stroke), and
## a running generator shakes a little and puffs exhaust.
## The charge settles as it dries and chars (TcBed.volume_frac): its mesh is
## one unit high and the shader draws it at the height it has now; the
## headspace gas and the vapour start from that surface.
## Cosmetic motion runs on the lab's clock: nothing moves while the lab is
## paused, and it time-lapses (sqrt of the speed) instead of strobing.

const SectionShader := preload("res://core/tclab/process/shaders/tc_section.gdshader")
const XrayShader := preload("res://core/tclab/process/shaders/tc_xray.gdshader")
const GasShader := preload("res://core/tclab/process/shaders/tc_gas.gdshader")
const LiquidShader := preload("res://core/tclab/process/shaders/tc_liquid.gdshader")
const BedShader := preload("res://core/tclab/process/shaders/tc_bed.gdshader")
const SmokeShader := preload("res://core/tclab/process/shaders/tc_smoke.gdshader")

const MM := 0.001
const TUBE_SIDES := 12
const MODES := [["solid", "Solid"], ["section", "Section"], ["xray", "X-ray"]]
const CUTS := [["facing", "Facing me"], ["across", "Left / right"], ["along", "Front / back"]]
const NO_CUT := Vector4(0.0, 0.0, 1.0, 1.0e6)
const BED_EVERY_S := 0.25
const MAX_DRIPS := 3
## Liquid colours by species (by mass).
const LIQ_COLORS := {
	"H2O": Color(0.42, 0.62, 0.82, 0.62), "acetic": Color(0.72, 0.50, 0.22, 0.75),
	"tar": Color(0.16, 0.09, 0.04, 0.95), "ethanol": Color(0.80, 0.88, 0.95, 0.5),
	"oil": Color(0.78, 0.58, 0.20, 0.85), "wax": Color(0.90, 0.86, 0.70, 0.95)}
## Air does not show; everything else tints the fog.
const CLEAR_GASES := ["N2", "O2"]

var mode := "section"
var cut := "facing"
var cut_offset := 0.0          # fraction of the assembly's half-size
var show_contents := true
var builder: TcBuilder = null
var camera: Camera3D = null
var sim: TcProcSim = null
var design: Dictionary = {}
var pivot_cv := -1             # the cut goes through this volume's middle

var _contents: Node3D
var _gas: Array = []           # [{cv, mat, polys: [[a, b]], phase}]
var _liq: Array = []           # [{cv, mat, y_lo, y_hi}]
var _bed: Dictionary = {}      # {mi, mat, img, tex}
var _head: Dictionary = {}     # vessel headspace gas {mat, phase}
var _pool: Dictionary = {}     # vessel liquid {mat, disc, disc_mat}
var _smoke_mat: ShaderMaterial = null   # vapour puffs inside the vessel
var _live: Node3D                # moving unit parts (drawn in every look)
var _floats: Array = []          # [{unit (index in sim.units), part, node, stroke_m}]
var _gens: Array = []            # [{part, node (the built part), xf, emitter}]
var _hidden: StandardMaterial3D = null
var _bed_top := 0.0             # the charge's height now (m, vessel frame)
var _emit := {}                # name → GPUParticles3D
var _drip_cvs: Array = []
var _sect_mats := {}
var _xray_mats := {}
var _plane := NO_CUT
var _swirl := 0.0
var _bed_acc := 0.0
var _last_liq := PackedFloat64Array()
var _last_t := -1.0
var _cond := PackedFloat64Array()   # kg/h condensing per CV
var _vessel_xf := Transform3D.IDENTITY
var _centre := Vector3.ZERO
var _extent := 0.3


func setup(b: TcBuilder, cam: Camera3D) -> void:
	builder = b
	camera = cam
	_contents = Node3D.new()
	_contents.name = "Contents"
	add_child(_contents)
	_live = Node3D.new()
	_live.name = "Live"
	add_child(_live)


## A new run (or a new design): rebuild the contents from the sim's network.
func rebuild(s: TcProcSim, d: Dictionary) -> void:
	sim = s
	design = d
	for c in _contents.get_children():
		_contents.remove_child(c)
		c.queue_free()
	for c2 in _live.get_children():
		_live.remove_child(c2)
		c2.queue_free()
	for gn in _gens:
		if is_instance_valid(gn["node"]):
			(gn["node"] as Node3D).transform = gn["xf"]
	_floats = []
	_gens = []
	_gas = []
	_liq = []
	_bed = {}
	_head = {}
	_pool = {}
	_smoke_mat = null
	_bed_top = 0.0
	_emit = {}
	_drip_cvs = []
	_last_t = -1.0
	_plane = Vector4(0, 0, 0, -1)   # new materials: push the plane again
	var bb: AABB = (d.get("stats", {}) as Dictionary).get("bounds_mm", AABB())
	_centre = (bb.position + bb.size * 0.5) * MM
	_extent = maxf(bb.size.length() * 0.5 * MM, 0.05)
	if sim == null:
		apply_mode()
		return
	_vessel_xf = TcBuilder.to_m(sim.vessel_xf)
	_last_liq.resize(sim.n_cv)
	_last_liq.fill(0.0)
	_cond.resize(sim.n_cv)
	_cond.fill(0.0)
	var cvs: Array = sim.net["cvs"]
	for i in cvs.size():
		var cv: Dictionary = cvs[i]
		var role := str(cv["role"])
		if role in ["vessel", "jacket", "coolant"]:
			continue
		var polys: Array = []
		for pl in cv["path"]:
			var o := PackedVector3Array()
			for v in pl:
				if o.is_empty() or (o[o.size() - 1].distance_to(v * MM) > 1.0e-4):
					o.append(v * MM)
			if o.size() >= 2:
				polys.append(o)
		if polys.is_empty():
			continue
		var r := maxf(float(cv["r_in_m"]) * 0.88, 0.003)
		var mesh := tube_mesh(polys, r, false)
		var gm := ShaderMaterial.new()
		gm.shader = GasShader
		gm.set_shader_parameter("cell_m", clampf(r * 2.2, 0.01, 0.08))
		var gi := _mi("Gas_%d" % i, mesh, gm)
		gi.set_meta("tc_cv", i)
		var ends: Array = []
		for pl in polys:
			ends.append([pl[0], pl[pl.size() - 1]])
		_gas.append({"cv": i, "mat": gm, "ends": ends, "phase": 0.0})
		var lm := ShaderMaterial.new()
		lm.shader = LiquidShader
		var lmesh := tube_mesh(polys, r * 0.97, false)
		_mi("Liquid_%d" % i, lmesh, lm)
		var ylo := INF
		var yhi := -INF
		for pl in polys:
			for v in pl:
				ylo = minf(ylo, v.y)
				yhi = maxf(yhi, v.y)
		_liq.append({"cv": i, "mat": lm, "y_lo": ylo - r, "y_hi": yhi + r})
	if sim.vessel_cv >= 0:
		_build_vessel(cvs[sim.vessel_cv])
	_build_emitters()
	_build_units()
	apply_mode()
	update_view(0.0, false, 1.0)


func _mi(nm: String, mesh: Mesh, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else _contents).add_child(mi)
	return mi


func _build_vessel(cv: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Vessel"
	holder.transform = _vessel_xf
	_contents.add_child(holder)
	var R := float(cv["r_in_m"]) * 0.985
	var H := maxf(float(cv.get("height_m", 0.3)), 0.05)
	var bed_h := 0.0
	if sim.bed != null and not sim.bed.is_empty():
		bed_h = sim.bed.height_m
		_bed_top = bed_h
		var bm := ShaderMaterial.new()
		bm.shader = BedShader
		var nd := sim.bed.domains.size()
		var img := Image.create(TcBed.NR, TcBed.NZ * nd, false, Image.FORMAT_RGBA8)
		var tex := ImageTexture.create_from_image(img)
		bm.set_shader_parameter("cells", tex)
		bm.set_shader_parameter("n_dom", nd)
		bm.set_shader_parameter("nr", TcBed.NR)
		bm.set_shader_parameter("bed_h", bed_h)
		var doms: Array = []
		for di in 4:
			if di < nd:
				var d: Dictionary = sim.bed.domains[di]
				var c: Vector3 = d["center_mm"]
				var rin := TcBed.R_ELEMENT if not sim.heater_parts.is_empty() else 0.0
				doms.append(Vector4(c.x * MM, c.z * MM, rin, float(d["r_out_m"])))
			else:
				doms.append(Vector4(0, 0, 0, 1))
		bm.set_shader_parameter("dom", doms)
		var piece := 0.004 if sim.bed.plastic != "" else 0.011
		bm.set_shader_parameter("piece_m", piece)
		bm.set_shader_parameter("heap_m", minf(piece, bed_h * 0.08))
		var bi := _mi("Charge", charge_mesh(R), bm, holder)
		bi.custom_aabb = AABB(Vector3(-R, 0, -R), Vector3(R * 2.0, bed_h + 0.05, R * 2.0))
		_bed = {"mi": bi, "mat": bm, "img": img, "tex": tex, "piece": piece}
	# The headspace above the charge (or the whole vessel for a liquid charge).
	var hm := ShaderMaterial.new()
	hm.shader = GasShader
	hm.set_shader_parameter("cell_m", clampf(R * 0.5, 0.03, 0.12))
	# One mesh over the vessel's whole height, squeezed onto what is above
	# the charge as the charge settles.
	var hmesh := tube_mesh([PackedVector3Array([Vector3(0, 0.0, 0), Vector3(0, H, 0)])], R * 0.97, false)
	var hi := _mi("Headspace", hmesh, hm, holder)
	_head = {"mat": hm, "phase": 0.0, "R": R, "H": H, "bed_h": bed_h, "mi": hi, "dome": _dome_m(cv), "cap": _dome_is_cap(cv)}
	_fit_headspace()
	_paint_bed()
	# A liquid charge (a kettle, a still): the pool and its surface.
	var pm := ShaderMaterial.new()
	pm.shader = LiquidShader
	_mi("Pool", tube_mesh([PackedVector3Array([Vector3(0, 0.0, 0), Vector3(0, H, 0)])], R, false), pm, holder)
	var dm := ShaderMaterial.new()
	dm.shader = LiquidShader
	dm.set_shader_parameter("level_y", 1.0e6)
	var disc := _mi("PoolSurface", disc_mesh(R), dm, holder)
	disc.visible = false
	_pool = {"mat": pm, "disc": disc, "disc_mat": dm, "R": R}


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

func set_mode(m: String) -> void:
	mode = m
	apply_mode()


func set_cut(c: String) -> void:
	cut = c


func set_cut_offset(f: float) -> void:
	cut_offset = clampf(f, -1.0, 1.0)


func set_show_contents(on: bool) -> void:
	show_contents = on
	_contents.visible = on and mode != "solid"


## Whether the vessel's lid is a spherical cap (else a dished head).
func _dome_is_cap(cv: Dictionary) -> bool:
	var parts: Dictionary = (design.get("res", {}) as Dictionary).get("parts", {})
	for pid in cv.get("parts", []):
		var b: Dictionary = (parts.get(str(pid), {}) as Dictionary).get("built", {})
		if str(b.get("type", "")) == "vessel":
			var p: Dictionary = b.get("params", {})
			return not p.is_empty() and TcVessel.has_lid(p) and str(p.get("lid_shape", "")) == "cap"
	return false


## The moving parts of the process units on the line.
func _build_units() -> void:
	var parts: Dictionary = (design.get("res", {}) as Dictionary).get("parts", {})
	for ui in sim.units.size():
		var u: Dictionary = sim.units[ui]
		var pid := str(u.get("part", ""))
		var pd: Dictionary = parts.get(pid, {})
		if pd.is_empty():
			continue
		var b: Dictionary = pd["built"]
		var xf := TcBuilder.to_m(pd["xf"])
		var ud: Dictionary = b.get("unit", {})
		match str(u["kind"]):
			"holder":
				var p: Dictionary = b.get("params", {})
				var g := TcGeom.new()
				TcUnits.gas_holder(g, str(b.get("size", "2")), float(p.get("volume_l", 100.0)), float(p.get("hold_kpa", 0.5)),
					str(p.get("style", "bell")), "float", 0.0)
				var at := Node3D.new()
				at.name = "FloatAt_%s" % pid
				at.transform = xf
				_live.add_child(at)
				var mi := MeshInstance3D.new()
				mi.name = "Float"
				mi.mesh = TcBuilder.geo_to_mesh(g, null)
				at.add_child(mi)
				_floats.append({"unit": ui, "part": pid, "node": mi, "stroke_m": float(ud.get("stroke_mm", 300.0)) * MM})
			"engine":
				var node := builder.get_node_or_null("P_%s" % pid) as Node3D if builder != null else null
				var dir: Vector3 = ud.get("exhaust_dir", Vector3.UP)
				var nm := "Exhaust_%s" % pid
				var e := _emitter(nm, Vector3(0.004, 0.004, 0.004), (xf.basis * dir).normalized(), 0.25, 0.5, Vector3(0, 0.3, 0), 1.0,
					Vector2(0.02, 0.085), 20, _live)
				e.position = xf * ((ud.get("exhaust_mm", Vector3.ZERO) as Vector3) * MM)
				_gens.append({"part": pid, "node": node, "xf": node.transform if node != null else Transform3D.IDENTITY, "emitter": nm})


## Floats to where the gas has them; a running generator shakes.
func _update_units(delta: float, running: bool) -> void:
	for f in _floats:
		var ui := int(f["unit"])
		if ui >= sim.units.size():
			continue
		var want := sim.holder_fill(sim.units[ui]) * float(f["stroke_m"])
		var n: Node3D = f["node"]
		var y := n.position.y
		# Eased while it runs; straight there on a scrub or a pause.
		n.position = Vector3(0, lerpf(y, want, 1.0 - exp(-delta * 8.0)) if running and delta > 0.0 else want, 0)
	for gn in _gens:
		var node: Node3D = gn["node"]
		if node == null or not is_instance_valid(node):
			continue
		var xf: Transform3D = gn["xf"]
		var kw := float(sim.engine_kw.get(str(gn["part"]), 0.0))
		if running and kw > 0.01:
			var t := Time.get_ticks_msec() * 0.001
			xf.origin += Vector3(sin(t * 87.0) * 0.0007, absf(sin(t * 61.0)) * 0.0006, cos(t * 73.0) * 0.0005)
		node.transform = xf


## Put the built parts back as they were (the panel is leaving Process mode).
func release() -> void:
	for gn in _gens:
		if is_instance_valid(gn["node"]):
			(gn["node"] as Node3D).transform = gn["xf"]
	if builder == null:
		return
	for n in builder.get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			mi.set_surface_override_material(si, null)


func _hidden_mat() -> StandardMaterial3D:
	if _hidden == null:
		_hidden = StandardMaterial3D.new()
		_hidden.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hidden.albedo_color = Color(0, 0, 0, 0)
		_hidden.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hidden.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return _hidden


## The inside height of the vessel's lid or top head above its shell (m).
func _dome_m(cv: Dictionary) -> float:
	var parts: Dictionary = (design.get("res", {}) as Dictionary).get("parts", {})
	for pid in cv.get("parts", []):
		var b: Dictionary = (parts.get(str(pid), {}) as Dictionary).get("built", {})
		if str(b.get("type", "")) != "vessel":
			continue
		var p: Dictionary = b.get("params", {})
		if p.is_empty():
			return 0.0
		if TcVessel.has_lid(p):
			return TcVessel.lid_depth(p) * MM
		return TcVessel.head_depth(p, "top") * MM
	return 0.0


## The headspace gas sits on the charge as it is now.
func _fit_headspace() -> void:
	if _head.is_empty():
		return
	var mi: MeshInstance3D = _head["mi"]
	var H := float(_head["H"])
	var y0 := minf(_bed_top + 0.003, H - 0.01) if _bed_top > 0.0 else 0.0
	mi.position = Vector3(0, y0, 0)
	mi.scale = Vector3(1.0, maxf(H - y0, 0.01) / maxf(H, 0.01), 1.0)


## Put the right materials on every built part for the mode.
func apply_mode() -> void:
	_plane = Vector4(0, 0, 0, -1)
	if _contents != null:
		_contents.visible = show_contents and mode != "solid"
	# The live floats wear the look too.
	var floats_of := {}
	for f in _floats:
		floats_of["P_%s" % str(f["part"])] = true
		var fm: MeshInstance3D = f["node"]
		for si2 in fm.mesh.get_surface_count():
			var k2 := (fm.mesh as ArrayMesh).surface_get_name(si2)
			fm.set_surface_override_material(si2, _section_mat(k2) if mode == "section" else (_xray_mat(k2) if mode == "xray" else null))
	if builder == null:
		return
	for n in builder.get_children():
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var key := (mi.mesh as ArrayMesh).surface_get_name(si) if mi.mesh is ArrayMesh else ""
			var m: Material = null
			if mode == "section":
				m = _section_mat(key)
			elif mode == "xray":
				m = _xray_mat(key)
			# A gasometer's built float gives way to the live one.
			if key.begins_with("bell") and floats_of.has(str(mi.name)):
				m = _hidden_mat()
			mi.set_surface_override_material(si, m)
		if mode != "solid":
			mi.material_overlay = null
			mi.set_instance_shader_parameter("tint", Color(0, 0, 0, 0))
			mi.set_instance_shader_parameter("glow", Color(0, 0, 0, 0))


func _section_mat(key: String) -> ShaderMaterial:
	if _sect_mats.has(key):
		return _sect_mats[key]
	var m := ShaderMaterial.new()
	var src := TcBuilder.material_for(key) as BaseMaterial3D
	if key == "glass":
		m.shader = XrayShader
		m.set_shader_parameter("ghost", Color(0.80, 0.90, 0.95))
		m.set_shader_parameter("base_alpha", 0.14)
		m.set_shader_parameter("rim_alpha", 0.45)
	else:
		m.shader = SectionShader
		if src != null:
			m.set_shader_parameter("albedo", src.albedo_color)
			m.set_shader_parameter("metallic", src.metallic)
			m.set_shader_parameter("roughness", src.roughness)
			# The cut face of steel is a little brighter than its skin (fresh metal).
			m.set_shader_parameter("cap_color", Color(src.albedo_color).lerp(Color(0.72, 0.72, 0.74), 0.4))
	_sect_mats[key] = m
	return m


func _xray_mat(key: String) -> ShaderMaterial:
	if _xray_mats.has(key):
		return _xray_mats[key]
	var m := ShaderMaterial.new()
	m.shader = XrayShader
	var src := TcBuilder.material_for(key) as BaseMaterial3D
	var c := Color(0.62, 0.76, 0.90)
	if src != null and key != "steel" and key != "hardware":
		c = Color(src.albedo_color).lerp(c, 0.45)
	m.set_shader_parameter("ghost", c)
	if key == "glass":
		m.set_shader_parameter("base_alpha", 0.10)
	_xray_mats[key] = m
	return m


## Per-part temperature tint (section / X-ray; the solid view uses the
## panel's overlay). temps: part id → °C.
func apply_tints(temps: Dictionary, heat_color: Callable) -> void:
	if builder == null or mode == "solid":
		return
	var glow := _element_glows()
	for pid in temps.keys():
		var n := builder.get_node_or_null("P_%s" % pid)
		if not (n is GeometryInstance3D):
			continue
		var t := float(temps[pid])
		var c: Color = heat_color.call(t) if is_finite(t) else Color(0, 0, 0, 0)
		(n as GeometryInstance3D).set_instance_shader_parameter("tint", c)
		(n as GeometryInstance3D).set_instance_shader_parameter("glow", glow.get(str(pid), Color(0, 0, 0, 0)))


func _element_glows() -> Dictionary:
	var out := {}
	if sim == null:
		return out
	for k in sim.heater_parts.size():
		if k < sim.element_t.size():
			out[str(sim.heater_parts[k])] = glow_for(float(sim.element_t[k]) - 273.15)
	return out


## Hot metal's own light (°C): none below ~380 °C, dull red to yellow-white.
static func glow_for(t_c: float) -> Color:
	if t_c < 380.0:
		return Color(0, 0, 0, 0)
	var u := clampf((t_c - 380.0) / 620.0, 0.0, 1.0)
	var c := Color(0.75, 0.08, 0.02).lerp(Color(1.0, 0.42, 0.08), clampf(u * 2.0, 0.0, 1.0))
	c = c.lerp(Color(1.0, 0.85, 0.55), clampf(u * 2.0 - 1.0, 0.0, 1.0))
	c.a = clampf(0.2 + u, 0.0, 1.0)
	return c


# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

## delta: real seconds; running: the lab clock is moving; rate: lab seconds
## per real second.
func update_view(delta: float, running: bool, rate: float) -> void:
	if sim == null or _contents == null:
		return
	var mult := 0.0
	if running:
		mult = clampf(sqrt(maxf(rate, 0.0)) / 3.0, 0.3, 3.0)
	_swirl += delta * mult * 0.4
	_update_plane()
	_update_units(delta, running)
	if mode == "solid" or not show_contents:
		_set_emitting(false)
		return
	var lab_dt := 0.0
	if _last_t >= 0.0:
		lab_dt = sim.t_s - _last_t
	if lab_dt < 0.0 or lab_dt > 1800.0:
		_last_liq.fill(-1.0)   # a seek: start the condensing rate again
	_last_t = sim.t_s
	for g in _gas:
		var i := int(g["cv"])
		var v := _cv_speed(i)
		var sgn := _flow_sign(i, g["ends"])
		g["phase"] = float(g["phase"]) + sgn * _display_speed(v) * mult * delta
		var mat: ShaderMaterial = g["mat"]
		var look := gas_look(sim.gas[i])
		mat.set_shader_parameter("gas_color", look[0])
		mat.set_shader_parameter("density", float(look[1]) * (1.0 if v > 1.0e-4 else 0.7))
		mat.set_shader_parameter("phase", float(g["phase"]))
		mat.set_shader_parameter("swirl", _swirl)
	for l in _liq:
		var i := int(l["cv"])
		var lv := _liq_l(i)
		var mat: ShaderMaterial = l["mat"]
		var cv: Dictionary = sim.net["cvs"][i]
		var vol_l := maxf(float(cv["volume_m3"]) * 1000.0, 1.0e-6)
		var frac := clampf(lv / vol_l, 0.0, 1.0)
		if lv < 1.0e-4:
			mat.set_shader_parameter("level_y", -1.0e6)
		else:
			var y := float(l["y_lo"]) + maxf(frac, 0.04) * (float(l["y_hi"]) - float(l["y_lo"]))
			mat.set_shader_parameter("level_y", (global_transform * Vector3(0, y, 0)).y)
		mat.set_shader_parameter("liquid_color", liquid_look(sim.liq[i]))
		mat.set_shader_parameter("swirl", _swirl)
		# Condensing here: the liquid's rise over lab time.
		if lab_dt > 0.0 and _last_liq[i] >= 0.0:
			var kg_h := maxf(lv - _last_liq[i], 0.0) / lab_dt * 3600.0
			_cond[i] = lerpf(_cond[i], kg_h, 0.3)
		_last_liq[i] = lv
	_update_vessel(delta, mult)
	_bed_acc += delta
	if _bed_acc >= BED_EVERY_S:
		_bed_acc = 0.0
		_paint_bed()
	_update_emitters(running, mult)


func _liq_l(i: int) -> float:
	return sim._liq_volume(sim.liq[i]) * 1000.0


## How fast the gas leaves a volume (m/s, lab time).
func _cv_speed(i: int) -> float:
	var v := 0.0
	if i < sim._cv_links.size():
		for li in sim._cv_links[i]:
			v = maxf(v, absf(sim.vel_link[int(li)]))
	return v


## +1 when the gas runs from a polyline's start to its end.
func _flow_sign(i: int, ends: Array) -> float:
	var out := Vector3.ZERO
	var w := 0.0
	if i < sim._cv_links.size():
		for li in sim._cv_links[i]:
			var l: Dictionary = sim.net["links"][int(li)]
			var f := sim.flow_link[int(li)]
			var leaving := (int(l["a"]) == i and f > 0.0) or (int(l["b"]) == i and f < 0.0)
			if leaving:
				out += (l["at_mm"] as Vector3) * MM * absf(f)
				w += absf(f)
	if w <= 0.0 or ends.is_empty():
		return 1.0
	out /= w
	var e: Array = ends[0]
	return 1.0 if (e[1] as Vector3).distance_to(out) <= (e[0] as Vector3).distance_to(out) else -1.0


## A drift speed that reads: slow gas still visibly moves, fast gas does not
## strobe (m/s on screen at 1×).
static func _display_speed(v_ms: float) -> float:
	if v_ms < 1.0e-5:
		return 0.0
	return clampf(0.02 + 0.22 * sqrt(v_ms), 0.02, 0.45)


## [colour, density] of a gas: air is clear, steam white, woodgas yellowish,
## tar smoke amber.
static func gas_look(g: PackedFloat64Array) -> Array:
	var n := 0.0
	for s in g.size():
		n += g[s]
	if n <= 0.0:
		return [Color(1, 1, 1), 0.0]
	var c := Color(0, 0, 0)
	var w := 0.0
	var clear := 0.0
	for s in g.size():
		var x := g[s] / n
		var sp := str(TcProcSim.SP[s])
		if sp in CLEAR_GASES:
			clear += x
			continue
		var col := TcSpecies.color(sp)
		var k := x * (6.0 if sp == "tar" else (2.5 if sp in ["acetic", "oil", "wax"] else 1.0))
		c += col * k
		w += k
	if w <= 0.0:
		return [Color(0.9, 0.93, 1.0), 0.05]
	c /= w
	var dens := clampf(0.06 + 0.6 * (1.0 - clear) + 0.25 * minf(g[TcProcSim.I_TAR] / n * 20.0, 1.0), 0.04, 0.8)
	return [Color(c.r, c.g, c.b, 1.0), dens]


static func liquid_look(l: PackedFloat64Array) -> Color:
	var c := Color(0, 0, 0, 0)
	var w := 0.0
	for s in TcProcSim.COND:
		if l[s] <= 0.0:
			continue
		var sp := str(TcProcSim.SP[s])
		var kg := l[s] * TcSpecies.molar_mass_kg(sp)
		c += (LIQ_COLORS.get(sp, Color(0.5, 0.5, 0.5, 0.8)) as Color) * kg
		w += kg
	if w <= 0.0:
		return LIQ_COLORS["H2O"]
	return c / w


func _update_vessel(delta: float, mult: float) -> void:
	if _head.is_empty() or sim.vessel_cv < 0:
		return
	var i := sim.vessel_cv
	var hm: ShaderMaterial = _head["mat"]
	var look := gas_look(sim.gas[i])
	var R := float(_head["R"])
	var p := maxf(sim.p_cv[i], 1.0)
	var n_s := maxf(sim.cv_flow[i], 0.0)
	var v := n_s * TcSpecies.R * sim.gas_t(i) / p / (PI * R * R)   # m/s rising
	_head["phase"] = float(_head["phase"]) + _display_speed(v) * mult * delta
	hm.set_shader_parameter("gas_color", look[0])
	hm.set_shader_parameter("density", float(look[1]) * 0.7)
	hm.set_shader_parameter("phase", float(_head["phase"]))
	hm.set_shader_parameter("swirl", _swirl)
	# A liquid charge.
	var lv := _liq_l(i) * 0.001
	var pm: ShaderMaterial = _pool["mat"]
	var disc: MeshInstance3D = _pool["disc"]
	if lv > 1.0e-5:
		var h := minf(lv / (PI * R * R), float(_head["H"]))
		var wy := (global_transform * _vessel_xf * Vector3(0, h, 0)).y
		pm.set_shader_parameter("level_y", wy)
		pm.set_shader_parameter("liquid_color", liquid_look(sim.liq[i]))
		var boiling := (sim.bed == null or sim.bed.is_empty()) and sim.cv_flow[i] > 1.0e-4
		pm.set_shader_parameter("ripple", 1.0 if boiling else 0.0)
		pm.set_shader_parameter("swirl", _swirl)
		disc.visible = true
		disc.position = Vector3(0, h, 0)
		(_pool["disc_mat"] as ShaderMaterial).set_shader_parameter("liquid_color", liquid_look(sim.liq[i]))
	else:
		pm.set_shader_parameter("level_y", -1.0e6)
		disc.visible = false


## The bed's cells into the charge texture.
func _paint_bed() -> void:
	if _bed.is_empty() or sim.bed == null:
		return
	var img: Image = _bed["img"]
	var nd := sim.bed.domains.size()
	for di in nd:
		var d: Dictionary = sim.bed.domains[di]
		for k in TcBed.NZ:
			for j in TcBed.NR:
				var i := k * TcBed.NR + j
				img.set_pixel(j, di * TcBed.NZ + k, cell_color(d, i))
	(_bed["tex"] as ImageTexture).update(img)
	var mat: ShaderMaterial = _bed["mat"]
	# The pile settles as it dries and chars; its pieces shrink with it.
	var frac := sim.bed.volume_frac()
	_bed_top = sim.bed.height_m * frac
	mat.set_shader_parameter("bed_h", _bed_top)
	mat.set_shader_parameter("piece_m", float(_bed["piece"]) * pow(frac, 1.0 / 3.0))
	mat.set_shader_parameter("flicker", _swirl)
	_fit_headspace()
	var ve: GPUParticles3D = _emit.get("Vapour", null)
	if ve != null:
		ve.position = Vector3(0, _bed_top + 0.01, 0)
	if _smoke_mat != null:
		_smoke_mat.set_shader_parameter("to_vessel", (global_transform * _vessel_xf).affine_inverse())
		_smoke_mat.set_shader_parameter("floor_y", maxf(_bed_top - 0.01, 0.0))
	var gl: Array = []
	var eg := _element_glows()
	for di in 4:
		var c := Color(0, 0, 0, 0)
		if di < nd:
			c = eg.get(str((sim.bed.domains[di] as Dictionary).get("part", "")), Color(0, 0, 0, 0))
		gl.append(Vector4(c.r, c.g, c.b, c.a))
	mat.set_shader_parameter("el_glow", gl)
	mat.set_shader_parameter("to_vessel", (global_transform * _vessel_xf).affine_inverse())


## One cell: rgb what it is, a its glow (0 below GLOW_FROM_C, 1 at
## GLOW_FULL_C: temperature alone, so a charge that cools goes back to black).
const GLOW_FROM_C := 420.0
const GLOW_FULL_C := 800.0


static func cell_color(d: Dictionary, i: int) -> Color:
	var t_c := float(d["T"][i]) - 273.15
	var wood := Color(0.78, 0.60, 0.38)
	var stage := TcBed.stage_at(d, i)
	var c: Color
	match stage:
		0:
			var mw := float(d["mw"][i])
			var wet := clampf(mw / maxf(float(d["v0"][i]) * 0.3, 1.0e-6), 0.0, 1.0)
			c = wood.lerp(Color(0.46, 0.38, 0.30), wet)
		1:
			c = wood.lerp(Color(0.62, 0.44, 0.26), clampf((t_c - 120.0) / 160.0, 0.0, 1.0))
		2:
			c = Color(0.55, 0.36, 0.20).lerp(Color(0.07, 0.06, 0.055), TcBed.converted_at(d, i))
		_:
			c = Color(0.05, 0.047, 0.045)
	var glow := 0.0
	if stage >= 2:
		glow = clampf((t_c - GLOW_FROM_C) / (GLOW_FULL_C - GLOW_FROM_C), 0.0, 1.0)
	return Color(c.r, c.g, c.b, glow)


# ---------------------------------------------------------------------------
# The section plane
# ---------------------------------------------------------------------------

func _update_plane() -> void:
	var p := NO_CUT
	if mode == "section" and camera != null:
		var pc := _pivot_world()
		var n := Vector3.ZERO
		var to_cam := camera.global_position - pc
		match cut:
			"across":
				n = Vector3(signf(to_cam.x) if absf(to_cam.x) > 1e-6 else 1.0, 0, 0)
			"along":
				n = Vector3(0, 0, signf(to_cam.z) if absf(to_cam.z) > 1e-6 else 1.0)
			_:
				n = Vector3(to_cam.x, 0, to_cam.z)
				n = n.normalized() if n.length() > 1e-6 else Vector3(0, 0, 1)
		var off := cut_offset * _extent
		p = Vector4(n.x, n.y, n.z, n.dot(pc) + off)
	if p.is_equal_approx(_plane):
		return
	_plane = p
	for m in _sect_mats.values():
		(m as ShaderMaterial).set_shader_parameter("cut_plane", p)
	for m in _xray_mats.values():
		(m as ShaderMaterial).set_shader_parameter("cut_plane", NO_CUT)
	for g in _gas:
		(g["mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
	for l in _liq:
		(l["mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
	if not _head.is_empty():
		(_head["mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
	if not _pool.is_empty():
		(_pool["mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
		(_pool["disc_mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
	if not _bed.is_empty():
		(_bed["mat"] as ShaderMaterial).set_shader_parameter("cut_plane", p)
	if _smoke_mat != null:
		_smoke_mat.set_shader_parameter("cut_plane", p)


func cut_plane() -> Vector4:
	return _plane


func _pivot_world() -> Vector3:
	if sim != null:
		var i := pivot_cv if pivot_cv >= 0 and pivot_cv < sim.n_cv else sim.vessel_cv
		if i >= 0 and i == sim.vessel_cv and not _head.is_empty():
			return global_transform * (_vessel_xf * Vector3(0, float(_head["H"]) * 0.5, 0))
		if i >= 0:
			return global_transform * ((sim.net["cvs"][i]["centroid_mm"] as Vector3) * MM)
	return global_transform * _centre


# ---------------------------------------------------------------------------
# Particles
# ---------------------------------------------------------------------------

func _build_emitters() -> void:
	if sim.vessel_cv >= 0 and not _head.is_empty():
		var vh: Node3D = _contents.get_node("Vessel")
		var R := float(_head["R"])
		var H := float(_head["H"])
		# Puffs drawn only inside the vessel: cut off at its wall and lid.
		_smoke_mat = ShaderMaterial.new()
		_smoke_mat.shader = SmokeShader
		_smoke_mat.set_shader_parameter("inner_r", R * 0.99)
		_smoke_mat.set_shader_parameter("top_y", H)
		_smoke_mat.set_shader_parameter("dome_h", maxf(float(_head["dome"]) - 0.004, 0.0))
		_smoke_mat.set_shader_parameter("dome_cap", 1.0 if bool(_head["cap"]) else 0.0)
		_smoke_mat.set_shader_parameter("soft", clampf(R * 0.18, 0.01, 0.04))
		_smoke_mat.set_shader_parameter("to_vessel", (global_transform * _vessel_xf).affine_inverse())
		var puff := minf(0.12, R * 0.75)
		var e := _emitter("Vapour", Vector3(R * 0.6, 0.004, R * 0.6), Vector3.UP, 0.03, 0.08,
			Vector3(0, 0.03, 0), clampf((H - float(_head["bed_h"]) * 0.5) / 0.06, 1.5, 6.0), Vector2(puff * 0.25, puff), 40, vh,
			_smoke_mat)
		e.position = Vector3(0, _bed_top + 0.01, 0)
		var b := _emitter("Bubbles", Vector3(R * 0.7, 0.004, R * 0.7), Vector3.UP, 0.06, 0.14,
			Vector3.ZERO, 1.6, Vector2(0.005, 0.012), 40, vh)
		b.position = Vector3(0, 0.01, 0)
	# The plume where the gas leaves.
	var out := _outlet_boundary()
	if not out.is_empty():
		var d: Vector3 = out["dir"]
		# A short jet straight out of the pipe end: the gas leaves through the
		# outlet (to a hose, a holder, a burner), it does not rise over the
		# reactor like smoke from an open pot.
		var pl := _emitter("Plume", Vector3(0.004, 0.004, 0.004), d, 0.05, 0.11, Vector3.ZERO, 0.9,
			Vector2(0.010, 0.032), 24, _contents)
		pl.position = (out["pos_mm"] as Vector3) * MM + d * 0.01
	for k in MAX_DRIPS:
		_emitter("Drips%d" % k, Vector3(0.01, 0.05, 0.01), Vector3.DOWN, 0.0, 0.02, Vector3(0, -0.5, 0), 1.2,
			Vector2(0.004, 0.006), 24, _contents)


func _outlet_boundary() -> Dictionary:
	var best := {}
	for b in sim.net["boundaries"]:
		var role := str(b["role"])
		if role == "product":
			return b
		if role in ["outlet", "atmosphere"] and best.is_empty():
			best = b
	return best


func _emitter(nm: String, extents: Vector3, dir: Vector3, v0: float, v1: float, grav: Vector3, life: float,
		size: Vector2, amount: int, parent: Node3D, mat: Material = null) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = amount
	p.lifetime = life
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents
	pm.direction = dir
	pm.spread = 14.0
	pm.initial_velocity_min = v0
	pm.initial_velocity_max = v1
	pm.gravity = grav
	pm.scale_min = 1.0
	pm.scale_max = 1.6
	var sc := Curve.new()
	sc.add_point(Vector2(0, size.x / size.y))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 0))
	gr.set_color(1, Color(1, 1, 1, 0))
	gr.add_point(0.15, Color(1, 1, 1, 1))
	gr.add_point(0.7, Color(1, 1, 1, 0.6))
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(size.y, size.y)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = FireVfx.soft_disc_texture()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = mat if mat != null else m
	p.draw_pass_1 = q
	parent.add_child(p)
	_emit[nm] = p
	return p


func _set_emitting(on: bool) -> void:
	for p in _emit.values():
		(p as GPUParticles3D).emitting = on and (p as GPUParticles3D).amount_ratio > 0.01


func _emit_set(nm: String, ratio: float, col: Color, running: bool, mult: float) -> void:
	var p: GPUParticles3D = _emit.get(nm, null)
	if p == null:
		return
	p.amount_ratio = clampf(ratio, 0.0, 1.0)
	var want := ratio > 0.01
	if p.emitting != want:
		p.emitting = want
	p.speed_scale = clampf(mult, 0.3, 2.0) if running else 0.0
	# Puffs frozen by a pause after their source stopped would hang there.
	p.visible = want or running
	(p.process_material as ParticleProcessMaterial).color = col


func _update_emitters(running: bool, mult: float) -> void:
	var i := sim.vessel_cv
	var bed := sim.bed != null and not sim.bed.is_empty()
	if i >= 0:
		var look := gas_look(sim.gas[i])
		var vc: Color = look[0]
		var flow := maxf(sim.cv_flow[i], 0.0)
		var pool := _liq_l(i) > 0.01
		_emit_set("Vapour", (flow / 0.006) if bed else 0.0, Color(vc.r, vc.g, vc.b, 0.35), running, mult)
		_emit_set("Bubbles", (flow / 0.004) if (pool and not bed) else 0.0, Color(0.95, 0.97, 1.0, 0.5), running, mult)
	var pr := 0.0
	for s in sim.product_rate.size():
		pr += sim.product_rate[s]
	var px := PackedFloat64Array()
	px.resize(TcProcSim.NS)
	for s in TcProcSim.NS:
		px[s] = sim.product_rate[s]
	var pl := gas_look(px)
	var pc: Color = pl[0]
	_emit_set("Plume", pr / 0.004, Color(pc.r, pc.g, pc.b, clampf(float(pl[1]) * 0.6, 0.12, 0.45)), running, mult)
	for gn in _gens:
		var kw := float(sim.engine_kw.get(str(gn["part"]), 0.0))
		_emit_set(str(gn["emitter"]), clampf(kw / 0.6, 0.35, 1.0) if kw > 0.01 else 0.0, Color(0.42, 0.42, 0.44, 0.45), running, mult)
	# Drips in the volumes condensing the most.
	var order: Array = []
	for k in sim.n_cv:
		if _cond[k] > 0.005:
			order.append(k)
	order.sort_custom(func(a: int, b: int) -> bool: return _cond[a] > _cond[b])
	for k in MAX_DRIPS:
		var nm := "Drips%d" % k
		var p: GPUParticles3D = _emit.get(nm, null)
		if p == null:
			continue
		if k >= order.size():
			_emit_set(nm, 0.0, Color.WHITE, running, mult)
			continue
		var cvi: int = order[k]
		if int(p.get_meta("cv", -1)) != cvi:
			p.set_meta("cv", cvi)
			var cv: Dictionary = sim.net["cvs"][cvi]
			var lo := Vector3(INF, INF, INF)
			var hi := -lo
			for pl2 in cv["path"]:
				for v in pl2:
					lo = lo.min(v * MM)
					hi = hi.max(v * MM)
			var r := float(cv["r_in_m"]) * 0.6
			p.position = (lo + hi) * 0.5
			var ext := (hi - lo) * 0.5
			(p.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(minf(ext.x, r) + 0.002, maxf(ext.y, 0.01), minf(ext.z, r) + 0.002)
		var lc := liquid_look(sim.liq[cvi])
		_emit_set(nm, _cond[cvi] / 0.25, Color(lc.r, lc.g, lc.b, 0.9), running, mult)


# ---------------------------------------------------------------------------
# Meshes
# ---------------------------------------------------------------------------

## A tube along polylines (metres), UV.x = distance along (m), UV.y = angle
## round (0..1). caps: close each end with a disc (a solid, for the charge).
static func tube_mesh(polys: Array, r: float, caps: bool) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for pl in polys:
		var pts: PackedVector3Array = pl
		var n := pts.size()
		if n < 2:
			continue
		var t0 := (pts[1] - pts[0]).normalized()
		var ref := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var nn := t0.cross(ref).normalized()
		var s := 0.0
		var base := verts.size()
		for k in n:
			var t: Vector3
			if k == 0:
				t = t0
			elif k == n - 1:
				t = (pts[k] - pts[k - 1]).normalized()
			else:
				t = ((pts[k + 1] - pts[k]).normalized() + (pts[k] - pts[k - 1]).normalized()).normalized()
			if t.length() < 0.5:
				t = (pts[k] - pts[k - 1]).normalized()
			# Parallel transport: keep the ring's frame from twisting.
			nn = (nn - t * nn.dot(t)).normalized()
			if nn.length() < 0.5:
				nn = t.cross(Vector3.RIGHT).normalized()
			var bn := t.cross(nn)
			if k > 0:
				s += pts[k].distance_to(pts[k - 1])
			for a in TUBE_SIDES + 1:
				var ang := TAU * float(a) / float(TUBE_SIDES)
				var dirv := nn * cos(ang) + bn * sin(ang)
				verts.append(pts[k] + dirv * r)
				norms.append(dirv)
				uvs.append(Vector2(s, float(a) / float(TUBE_SIDES)))
		var ring := TUBE_SIDES + 1
		for k in n - 1:
			for a in TUBE_SIDES:
				var i0 := base + k * ring + a
				var i1 := i0 + ring
				idx.append_array([i0, i1, i0 + 1, i0 + 1, i1, i1 + 1])
		if caps:
			for end in 2:
				var c := pts[0] if end == 0 else pts[n - 1]
				var tn := -(pts[1] - pts[0]).normalized() if end == 0 else (pts[n - 1] - pts[n - 2]).normalized()
				var ci := verts.size()
				verts.append(c)
				norms.append(tn)
				uvs.append(Vector2(0, 0))
				var rb := base + (0 if end == 0 else (n - 1) * ring)
				for a in TUBE_SIDES:
					verts.append(verts[rb + a])
					norms.append(tn)
					uvs.append(Vector2(0, 0))
				for a in TUBE_SIDES:
					var j0 := ci + 1 + a
					var j1 := ci + 1 + (a + 1) % TUBE_SIDES
					# Godot's front face is clockwise seen from outside.
					if end == 0:
						idx.append_array([ci, j0, j1])
					else:
						idx.append_array([ci, j1, j0])
	var am := ArrayMesh.new()
	if verts.is_empty():
		return am
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


## The charge: a cylinder ONE unit high (tc_bed.gdshader scales it to the
## charge's height) with a ringed top the shader heaps up. UV2.x = 1 on the
## top's vertices, UV2.y = how far they may rise (0 at the wall).
static func charge_mesh(r: float) -> ArrayMesh:
	var sides := TUBE_SIDES * 2
	var rings := 7
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	# Wall.
	for k in 2:
		for a in sides + 1:
			var ang := TAU * float(a) / float(sides)
			var d := Vector3(cos(ang), 0.0, sin(ang))
			verts.append(d * r + Vector3(0, float(k), 0))
			norms.append(d)
			uv2.append(Vector2(0, 0))
	for a in sides:
		var i0 := a
		var i1 := a + sides + 1
		idx.append_array([i0, i1, i0 + 1, i0 + 1, i1, i1 + 1])
	# Bottom and top: a centre and rings.
	for end in 2:
		var y := float(end)
		var n := Vector3.DOWN if end == 0 else Vector3.UP
		var ci := verts.size()
		verts.append(Vector3(0, y, 0))
		norms.append(n)
		uv2.append(Vector2(float(end), 1.0))
		for k in rings:
			var rr := r * float(k + 1) / float(rings)
			var rise := 1.0 - pow(float(k + 1) / float(rings), 3.0)
			for a in sides:
				# Every other ring is turned half a step, so the facets vary.
				var ang := TAU * (float(a) + (0.5 if k % 2 == 1 else 0.0)) / float(sides)
				verts.append(Vector3(cos(ang) * rr, y, sin(ang) * rr))
				norms.append(n)
				uv2.append(Vector2(float(end), rise))
		for a in sides:
			var j0 := ci + 1 + a
			var j1 := ci + 1 + (a + 1) % sides
			# Godot's front face is clockwise seen from outside.
			if end == 0:
				idx.append_array([ci, j0, j1])
			else:
				idx.append_array([ci, j1, j0])
		for k in rings - 1:
			var b0 := ci + 1 + k * sides
			var b1 := b0 + sides
			for a in sides:
				var a1 := (a + 1) % sides
				if end == 0:
					idx.append_array([b0 + a, b1 + a, b0 + a1, b0 + a1, b1 + a, b1 + a1])
				else:
					idx.append_array([b0 + a, b0 + a1, b1 + a, b0 + a1, b1 + a1, b1 + a])
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_INDEX] = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


static func disc_mesh(r: float) -> ArrayMesh:
	var verts := PackedVector3Array([Vector3.ZERO])
	var norms := PackedVector3Array([Vector3.UP])
	var idx := PackedInt32Array()
	for a in TUBE_SIDES * 2:
		var ang := TAU * float(a) / float(TUBE_SIDES * 2)
		verts.append(Vector3(cos(ang) * r, 0.0, sin(ang) * r))
		norms.append(Vector3.UP)
	for a in TUBE_SIDES * 2:
		idx.append_array([0, 1 + (a + 1) % (TUBE_SIDES * 2), 1 + a])
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


## For the harness: what the view is showing.
func debug_state() -> Dictionary:
	var on := []
	for k in _emit.keys():
		if (_emit[k] as GPUParticles3D).emitting:
			on.append(k)
	var liquids := 0
	for l in _liq:
		var lv: Variant = (l["mat"] as ShaderMaterial).get_shader_parameter("level_y")
		if lv != null and float(lv) > -1.0e5:
			liquids += 1
	return {"mode": mode, "plane": _plane, "gas_tubes": _gas.size(), "liquids_shown": liquids,
		"has_bed": not _bed.is_empty(), "emitting": on, "contents_visible": _contents.visible,
		"floats": _floats.map(func(f: Dictionary) -> Dictionary: return {"part": f["part"], "lift_m": (f["node"] as Node3D).position.y,
			"stroke_m": f["stroke_m"], "fill": sim.holder_fill(sim.units[int(f["unit"])]) if sim != null and int(f["unit"]) < sim.units.size() else 0.0}),
		"generators": _gens.size(),
		"bed_top_m": _bed_top, "bed_loaded_m": float(_head.get("bed_h", 0.0)), "smoke_contained": _smoke_mat != null}

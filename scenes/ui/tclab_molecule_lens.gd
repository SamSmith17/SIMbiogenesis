extends PanelContainer

## The TC Process Lab's molecule lens (Phase 6 of plans/TC_PROCESS_LAB_PLAN.md):
## a picture-in-picture over the studio showing a handful of molecules from
## the selected volume, read off the running TcProcSim.
##
##   gas      the volume's gas, sampled by mole fraction (~32 molecules),
##            flying at a speed that grows as √(T/M) and bouncing off the
##            box and each other (elastic)
##   liquid   what has condensed there, jostling in a layer at the bottom
##   solid    the vessel's charge: glucose units of cellulose turning to
##            carbon hexagons as it chars, with water held in the wood
## When the model reports a reaction in the volume (drying, boiling,
## condensing, pyrolysis, tar cracking, burning) the lens plays it on some
## of its molecules at a rate that follows the model's: bonds stretch and
## break, the atoms (matched by element, nothing appears or vanishes —
## TcMolecules.STORY balances) move into the products, and a caption says
## what happened.
##
## Moles are not simulated: the lens is a picture of the model's numbers.
## It moves on the lab's clock (frozen while the lab is paused) and costs
## nothing while closed (the panel frees it).

const BOX := 20.0                 # Å, the cube's edge
const N_GAS := 30
const N_LIQ := 18
const N_SOLID := 16
const GAS_ATOMS := 170            # the gas's atom budget (readability)
const LIQ_ATOMS := 110
const SYNC_S := 0.5
const STORY_S := 2.4
const MAX_STORIES := 2
const ATOM_SCALE := 0.42          # display radius / TcSpecies radius
const VIEW_SIZE := Vector2i(400, 300)

var sim: TcProcSim = null
var cv := -1
var title_label: Label
var caption: Label
var legend: Label
var viewport: SubViewport
var _world: Node3D
var _cam: Camera3D
var _atoms_mm: MultiMeshInstance3D
var _bonds_mm: MultiMeshInstance3D
var _mols: Array = []             # [{sp, region, pos, vel, rot, w, f}]
var _stories: Array = []          # [{atoms, bonds_from, bonds_to, t, products, text}]
var _acc := {}                    # reaction kind → events owed
var _alt := {}                    # reaction kind → which storyboard next
var _sync_acc := 0.0
var _rng := RandomNumberGenerator.new()
var _levels := {"liquid": 0.0, "solid": 0.0}
var _slots := {}                  # region → next lattice slot
var close_requested: Callable = Callable()
var shown_stories := 0            # for the harness


func _init() -> void:
	name = "MoleculeLens"
	_rng.seed = 1729
	add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.add_theme_font_override("font", UITheme.font("semibold"))
	title_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	head.add_child(title_label)
	var x := IconButton.close(func() -> void:
		if close_requested.is_valid():
			close_requested.call())
	head.add_child(x)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(VIEW_SIZE)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(svc)
	viewport = SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(viewport)
	_build_world()
	caption = Label.new()
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.custom_minimum_size = Vector2(VIEW_SIZE.x, 0)
	caption.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	caption.add_theme_color_override("font_color", UITheme.C_AMBER)
	v.add_child(caption)
	legend = Label.new()
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend.custom_minimum_size = Vector2(VIEW_SIZE.x, 0)
	legend.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	legend.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	v.add_child(legend)


func _build_world() -> void:
	_world = Node3D.new()
	viewport.add_child(_world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.1
	_world.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 40.0
	_cam.position = Vector3(0, BOX * 0.62, BOX * 2.15)
	_world.add_child(_cam)
	_cam.look_at_from_position(_cam.position, Vector3(0, BOX * 0.42, 0), Vector3.UP)
	_cam.current = true
	# The box's edges.
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var h := BOX * 0.5
	var c := [Vector3(-h, 0, -h), Vector3(h, 0, -h), Vector3(h, 0, h), Vector3(-h, 0, h)]
	for i in 4:
		for y in [0.0, BOX]:
			im.surface_add_vertex(c[i] + Vector3(0, y, 0))
			im.surface_add_vertex(c[(i + 1) % 4] + Vector3(0, y, 0))
		im.surface_add_vertex(c[i])
		im.surface_add_vertex(c[i] + Vector3(0, BOX, 0))
	im.surface_end()
	var box := MeshInstance3D.new()
	box.mesh = im
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.albedo_color = Color(0.35, 0.45, 0.6, 0.6)
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material_override = bm
	_world.add_child(box)
	_atoms_mm = _multimesh(_sphere(), true)
	_bonds_mm = _multimesh(_cylinder(), true)


func _sphere() -> Mesh:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = 14
	s.rings = 8
	return s


func _cylinder() -> Mesh:
	var c := CylinderMesh.new()
	c.top_radius = 1.0
	c.bottom_radius = 1.0
	c.height = 1.0
	c.radial_segments = 8
	c.rings = 1
	return c


func _multimesh(mesh: Mesh, colors: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.custom_aabb = AABB(Vector3(-BOX, -2, -BOX), Vector3(BOX * 2, BOX + 4, BOX * 2))
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.35
	m.metallic_specular = 0.6
	mi.material_override = m
	_world.add_child(mi)
	return mi


# ---------------------------------------------------------------------------
# Following the model
# ---------------------------------------------------------------------------

## Point the lens at a volume (rebuilds its molecules).
func show_cv(s: TcProcSim, i: int) -> void:
	sim = s
	cv = i
	_mols = []
	_stories = []
	_acc = {}
	_slots = {}
	_sync(true)


## Each frame from the panel. running: the lab clock moves; rate: lab
## seconds per real second.
func update_lens(delta: float, running: bool, rate: float) -> void:
	if sim == null or cv < 0 or cv >= sim.n_cv:
		return
	var mult := clampf(sqrt(maxf(rate, 0.0)) / 6.0, 0.25, 1.5) if running else 0.0
	_sync_acc += delta
	if _sync_acc >= SYNC_S:
		_sync_acc = 0.0
		_sync(false)
	var dt := delta * mult
	if dt > 0.0:
		_move(dt)
		_react(delta * (1.0 if running else 0.0), rate)
		_advance_stories(dt)
	_draw_all()


func _cv_t() -> float:
	return sim.gas_t(cv)


## Region heights and target populations from the model.
func _targets() -> Dictionary:
	var out := {"gas": {}, "liquid": {}, "solid": {}}
	var g: PackedFloat64Array = sim.gas[cv]
	var fr := {}
	for s in TcProcSim.NS:
		fr[str(TcProcSim.SP[s])] = g[s]
	out["gas"] = TcMolecules.sample_counts(fr, _n_for(fr, N_GAS, GAS_ATOMS))
	var l: PackedFloat64Array = sim.liq[cv]
	var lv := sim._liq_volume(l)
	var vol := maxf(float(sim.net["cvs"][cv]["volume_m3"]), 1e-9)
	var lfrac := clampf(lv / vol, 0.0, 1.0)
	_levels["liquid"] = 0.0
	if lv > 1e-7:
		_levels["liquid"] = clampf(0.12 + lfrac * 0.6, 0.12, 0.5) * BOX
		var lf := {}
		for s in TcProcSim.COND:
			lf[str(TcProcSim.SP[s])] = l[s]
		out["liquid"] = TcMolecules.sample_counts(lf, _n_for(lf, int(round(N_LIQ * clampf(0.4 + lfrac, 0.4, 1.0))), LIQ_ATOMS))
	_levels["solid"] = 0.0
	if cv == sim.vessel_cv and sim.bed != null and not sim.bed.is_empty():
		var t := sim.bed.totals()
		var dry0 := maxf(sim.bed.initial_dry_kg, 1e-9)
		var char_share := clampf(float(t["char_kg"]) / (dry0 * 0.35), 0.0, 1.0)
		var wood_share := clampf(float(t["wood_kg"]) / dry0, 0.0, 1.0)
		var units := int(round(N_SOLID * clampf(wood_share + char_share * 0.6, 0.25, 1.0)))
		var n_char := int(round(units * char_share / maxf(char_share + wood_share, 1e-6)))
		_levels["solid"] = 0.36 * BOX
		out["solid"] = {"glucose": units - n_char, "char": n_char}
		var wet := clampf(float(t["moisture_kg"]) / maxf(sim.bed.initial_moisture_kg, 1e-9), 0.0, 1.0)
		var n_w := int(round(8.0 * wet))
		if n_w > 0:
			(out["solid"] as Dictionary)["H2O"] = n_w
	return out


## How many molecules to draw so the atoms stay readable: a few big tar
## molecules, or many small gas ones.
static func _n_for(fracs: Dictionary, n_max: int, atom_budget: int) -> int:
	var tot := 0.0
	var at := 0.0
	for k in fracs.keys():
		var x := float(fracs[k])
		var na := (TcMolecules.layout(str(k)).get("atoms", []) as Array).size()
		if x <= 0.0 or na == 0:
			continue
		tot += x
		at += x * float(na)
	if tot <= 0.0:
		return n_max
	return clampi(int(float(atom_budget) / (at / tot)), mini(8, n_max), n_max)


func _sync(fresh: bool) -> void:
	var tg := _targets()
	for region in ["gas", "liquid", "solid"]:
		var want: Dictionary = tg[region]
		var have := {}
		for m in _mols:
			if str(m["region"]) == region:
				have[str(m["sp"])] = int(have.get(str(m["sp"]), 0)) + 1
		# Remove extras (the oldest first), add what is missing.
		for sp in have.keys():
			var extra := int(have[sp]) - int(want.get(sp, 0))
			var k := 0
			while extra > 0 and k < _mols.size():
				if str(_mols[k]["region"]) == region and str(_mols[k]["sp"]) == sp:
					_mols.remove_at(k)
					extra -= 1
				else:
					k += 1
		for sp2 in want.keys():
			var missing := int(want[sp2]) - int(have.get(sp2, 0))
			for _j in maxi(missing, 0):
				_mols.append(_new_mol(str(sp2), region))
	_thermostat()
	var name_cv := str(sim.net["cvs"][cv].get("label", "volume"))
	title_label.text = "Molecules in %s · %.0f °C" % [name_cv, _cv_t() - 273.15]
	var counts := {}
	for m2 in _mols:
		counts[str(m2["sp"])] = int(counts.get(str(m2["sp"]), 0)) + 1
	var parts: Array = []
	var ks := counts.keys()
	ks.sort_custom(func(a, b) -> bool: return int(counts[a]) > int(counts[b]))
	for k2 in ks:
		parts.append("%s %s ×%d" % [TcMolecules.display_name(str(k2)), TcMolecules.formula(str(k2)), int(counts[k2])])
	legend.text = " · ".join(parts) if not parts.is_empty() else "Nothing here yet."


func _new_mol(sp: String, region: String) -> Dictionary:
	var lay := TcMolecules.layout(sp)
	var r := float(lay.get("radius", 1.0))
	var pos := _spawn_pos(region, r)
	var dir := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)).normalized()
	var m := {"sp": sp, "region": region, "pos": pos, "vel": dir, "r": r,
		"rot": Quaternion(Vector3(_rng.randf(), _rng.randf(), _rng.randf()).normalized(), _rng.randf() * TAU),
		"w": Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.8,
		"f": _rng.randf_range(0.6, 1.4)}
	if region == "solid":
		m["home"] = pos
	return m


func _bounds(region: String) -> AABB:
	var h := BOX * 0.5
	var lo := 0.0
	var hi := BOX
	if region == "gas":
		lo = maxf(float(_levels["liquid"]), float(_levels["solid"]))
	elif region == "liquid":
		lo = float(_levels["solid"])
		hi = maxf(float(_levels["liquid"]), lo + 2.0)
	else:
		hi = maxf(float(_levels["solid"]), 2.0)
	return AABB(Vector3(-h, lo, -h), Vector3(BOX, hi - lo, BOX))


func _spawn_pos(region: String, r: float) -> Vector3:
	var b := _bounds(region)
	if region == "solid":
		# A loose lattice: 4 × 4 per layer.
		var k := int(_slots.get(region, 0))
		_slots[region] = k + 1
		var col := k % 4
		var row := (k / 4) % 4
		var lay := (k / 16) % 2
		return Vector3(-BOX * 0.375 + col * BOX * 0.25, 1.4 + lay * 2.4, -BOX * 0.375 + row * BOX * 0.25) + \
			Vector3(_rng.randf_range(-0.4, 0.4), _rng.randf_range(0.0, 0.6), _rng.randf_range(-0.4, 0.4))
	var m := minf(r, b.size.y * 0.45)
	return Vector3(_rng.randf_range(b.position.x + r, b.end.x - r), _rng.randf_range(b.position.y + m, b.end.y - m),
		_rng.randf_range(b.position.z + r, b.end.z - r))


## Speeds follow the volume's temperature (gas), slower in a liquid, a
## shiver in a solid.
func _thermostat() -> void:
	var t := _cv_t()
	for m in _mols:
		var v0: Vector3 = m["vel"]
		var target := TcMolecules.display_speed(str(m["sp"]), t) * float(m["f"])
		match str(m["region"]):
			"liquid":
				target *= 0.25
			"solid":
				target *= 0.08
		if v0.length() < 1e-6:
			v0 = Vector3(0.3, 0.2, -0.4)
		m["vel"] = v0.normalized() * lerpf(v0.length(), target, 0.6)


func _move(dt: float) -> void:
	for m in _mols:
		if bool(m.get("busy", false)):
			continue
		var region := str(m["region"])
		var b := _bounds(region)
		var r := minf(float(m["r"]), b.size.y * 0.45)
		var p: Vector3 = m["pos"]
		var v: Vector3 = m["vel"]
		if region == "solid":
			# Jiggle about a home position.
			var home: Vector3 = m["home"]
			v += (home - p) * 2.0 * dt + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * dt
		elif region == "liquid":
			v += Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * dt * 2.0
		p += v * dt
		for ax in 3:
			var lo := b.position[ax] + r
			var hi := b.end[ax] - r
			if lo > hi:
				lo = (b.position[ax] + b.end[ax]) * 0.5
				hi = lo
			if p[ax] < lo:
				p[ax] = lo
				v[ax] = absf(v[ax])
			elif p[ax] > hi:
				p[ax] = hi
				v[ax] = -absf(v[ax])
		m["pos"] = p
		m["vel"] = v
		var w: Vector3 = m["w"]
		if w.length() > 1e-6:
			m["rot"] = (Quaternion(w.normalized(), w.length() * dt * (0.2 if region == "solid" else 1.0)) * (m["rot"] as Quaternion)).normalized()
	# Gas molecules bounce off each other (elastic, by mass).
	var gas: Array = []
	for m in _mols:
		if str(m["region"]) == "gas" and not bool(m.get("busy", false)):
			gas.append(m)
	for i in gas.size():
		var a: Dictionary = gas[i]
		for j in range(i + 1, gas.size()):
			var b2: Dictionary = gas[j]
			var d: Vector3 = (b2["pos"] as Vector3) - (a["pos"] as Vector3)
			var rr := (float(a["r"]) + float(b2["r"])) * 0.7
			var dl := d.length()
			if dl < rr and dl > 1e-5:
				var n := d / dl
				var va: Vector3 = a["vel"]
				var vb: Vector3 = b2["vel"]
				var rel := (va - vb).dot(n)
				if rel > 0.0:
					var ma := TcMolecules.molar_mass(str(a["sp"]))
					var mb := TcMolecules.molar_mass(str(b2["sp"]))
					var jimp := 2.0 * rel / (ma + mb)
					a["vel"] = va - n * jimp * mb
					b2["vel"] = vb + n * jimp * ma


# ---------------------------------------------------------------------------
# Reactions
# ---------------------------------------------------------------------------

## The model's reaction rates (mol/s) → storyboards, a few a second at most.
func _react(real_dt: float, rate: float) -> void:
	if real_dt <= 0.0 or cv >= sim.react_rate.size():
		return
	var rr: Dictionary = sim.react_rate[cv]
	for kind in rr.keys():
		if not TcMolecules.STORY.has(str(kind)):
			continue
		var r := float(rr[kind])
		if r <= 0.0:
			continue
		var per_s := clampf(0.18 * log(1.0 + r * 1.0e4) / log(10.0), 0.0, 1.2) * clampf(sqrt(rate) / 10.0, 0.5, 1.5)
		_acc[kind] = float(_acc.get(kind, 0.0)) + per_s * real_dt
		if float(_acc[kind]) >= 1.0 and _stories.size() < MAX_STORIES:
			_acc[kind] = float(_acc[kind]) - 1.0
			_start_story(str(kind))
		elif float(_acc[kind]) > 2.0:
			_acc[kind] = 2.0


func _pick(sp: String, region: String) -> int:
	var cands: Array = []
	for i in _mols.size():
		var m: Dictionary = _mols[i]
		if bool(m.get("busy", false)):
			continue
		var ok := false
		match region:
			"gas_condensable":
				ok = str(m["region"]) == "gas" and TcSpecies.is_condensable(str(m["sp"])) and (sp == "*" or str(m["sp"]) == sp)
			_:
				ok = str(m["region"]) == region and (sp == "*" or str(m["sp"]) == sp)
		if ok:
			cands.append(i)
	if cands.is_empty():
		return -1
	return int(cands[_rng.randi() % cands.size()])


func _start_story(kind: String) -> void:
	var list: Array = TcMolecules.STORY[kind]
	var k := int(_alt.get(kind, 0)) % list.size()
	_alt[kind] = k + 1
	var st: Dictionary = list[k]
	var picked: Array = []
	var same := ""
	for f in st["from"]:
		var i := _pick(str(f[0]), str(f[1]))
		if i < 0 or i in picked:
			return
		picked.append(i)
		if str(f[0]) == "*":
			same = str(_mols[i]["sp"])
	# The reactants' atoms in the box.
	var atoms: Array = []          # [[el, from, to]]
	var bonds_from: Array = []
	var centre := Vector3.ZERO
	for i in picked:
		var m: Dictionary = _mols[i]
		m["busy"] = true
		centre += m["pos"] as Vector3
		var lay := TcMolecules.layout(str(m["sp"]))
		var base := atoms.size()
		for a in lay["atoms"]:
			atoms.append([str(a[0]), (m["pos"] as Vector3) + (m["rot"] as Quaternion) * (a[1] as Vector3), Vector3.ZERO, false])
		for bd in lay["bonds"]:
			bonds_from.append([base + int(bd[0]), base + int(bd[1]), int(bd[2])])
	centre /= float(picked.size())
	# Where the products go.
	var products: Array = []
	var to: Array = st["to"]
	var spread := 1.6 + 0.35 * float(to.size())
	for pi in to.size():
		var sp := str(to[pi][0])
		if sp == "=":
			sp = same
		var region := str(to[pi][1])
		var ang := TAU * float(pi) / float(maxi(to.size(), 1))
		var c := centre + Vector3(cos(ang), 0.0, sin(ang)) * (spread if to.size() > 1 else 0.0)
		if region == "gas" and centre.y < float(maxf(_levels["liquid"], _levels["solid"])) + 1.0:
			c.y = maxf(_levels["liquid"], _levels["solid"]) + 2.0 + 0.4 * float(pi % 3)
		elif region == "liquid":
			c.y = clampf(c.y, float(_levels["solid"]) + 1.0, maxf(float(_levels["liquid"]), float(_levels["solid"]) + 2.0) - 0.8)
		var b := _bounds(region)
		c.x = clampf(c.x, b.position.x + 1.0, b.end.x - 1.0)
		c.z = clampf(c.z, b.position.z + 1.0, b.end.z - 1.0)
		var rot := Quaternion(Vector3(_rng.randf(), _rng.randf(), _rng.randf()).normalized(), _rng.randf() * TAU)
		products.append({"sp": sp, "region": region, "centre": c, "rot": rot, "atoms": []})
	# Match the products' atoms to the reactants' by element (nearest free).
	var bonds_to: Array = []
	for p in products:
		var lay2 := TcMolecules.layout(str(p["sp"]))
		var idx: Array = []
		for a2 in lay2["atoms"]:
			var target: Vector3 = (p["centre"] as Vector3) + (p["rot"] as Quaternion) * (a2[1] as Vector3)
			var best := -1
			var bd2 := INF
			for ai in atoms.size():
				var at: Array = atoms[ai]
				if bool(at[3]) or str(at[0]) != str(a2[0]):
					continue
				var d := (at[1] as Vector3).distance_to(target)
				if d < bd2:
					bd2 = d
					best = ai
			if best < 0:
				atoms.append([str(a2[0]), centre, target, true])
				best = atoms.size() - 1
			else:
				atoms[best][2] = target
				atoms[best][3] = true
			idx.append(best)
		for bd3 in lay2["bonds"]:
			bonds_to.append([int(idx[int(bd3[0])]), int(idx[int(bd3[1])]), int(bd3[2])])
		p["atoms"] = idx
	# A reactant atom with nowhere to go stays put (balanced storyboards have none).
	for at2 in atoms:
		if not bool(at2[3]):
			at2[2] = at2[1]
	# Take the reactants out of the box; the story draws them now.
	picked.sort()
	picked.reverse()
	for i2 in picked:
		_mols.remove_at(i2)
	_stories.append({"atoms": atoms, "bonds_from": bonds_from, "bonds_to": bonds_to, "t": 0.0,
		"products": products, "text": str(st["text"]), "centre": centre})
	caption.text = str(st["text"])
	shown_stories += 1


func _advance_stories(dt: float) -> void:
	var keep: Array = []
	for s in _stories:
		s["t"] = float(s["t"]) + dt / STORY_S
		if float(s["t"]) >= 1.0:
			for p in s["products"]:
				var m := _new_mol(str(p["sp"]), str(p["region"]))
				m["pos"] = p["centre"]
				m["rot"] = p["rot"]
				if str(p["region"]) == "solid":
					m["home"] = p["centre"]
				var v := TcMolecules.display_speed(str(p["sp"]), _cv_t())
				m["vel"] = ((p["centre"] as Vector3) - (s["centre"] as Vector3) + Vector3(0, 0.5, 0)).normalized() * v
				_mols.append(m)
		else:
			keep.append(s)
	_stories = keep


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

static func atom_color(el: String) -> Color:
	return (TcSpecies.ATOMS.get(el, {"color": Color.GRAY}) as Dictionary)["color"]


static func atom_r(el: String) -> float:
	return float((TcSpecies.ATOMS.get(el, {"r": 0.6}) as Dictionary)["r"]) * ATOM_SCALE


func _draw_all() -> void:
	var ats: Array = []     # [pos, el]
	var bds: Array = []     # [a, b, order, color]
	for m in _mols:
		var lay := TcMolecules.layout(str(m["sp"]))
		var base := ats.size()
		for a in lay.get("atoms", []):
			ats.append([(m["pos"] as Vector3) + (m["rot"] as Quaternion) * (a[1] as Vector3), str(a[0])])
		for b in lay.get("bonds", []):
			bds.append([base + int(b[0]), base + int(b[1]), int(b[2]), Color(0.62, 0.64, 0.68)])
	for s in _stories:
		var t := float(s["t"])
		# Stretch (shake), move, settle.
		var u := smoothstep(0.25, 0.8, t)
		var shake := sin(t * 60.0) * 0.12 * (1.0 - smoothstep(0.15, 0.3, t)) * smoothstep(0.0, 0.08, t)
		var base2 := ats.size()
		for a2 in s["atoms"]:
			var p: Vector3 = (a2[1] as Vector3).lerp(a2[2] as Vector3, u)
			p += Vector3(shake, -shake, shake * 0.5)
			ats.append([p, str(a2[0])])
		var hot := Color(1.0, 0.62, 0.2)
		if u < 0.55:
			for b2 in s["bonds_from"]:
				bds.append([base2 + int(b2[0]), base2 + int(b2[1]), int(b2[2]), Color(0.62, 0.64, 0.68).lerp(hot, clampf(t * 3.0, 0.0, 1.0))])
		if u > 0.45:
			for b3 in s["bonds_to"]:
				bds.append([base2 + int(b3[0]), base2 + int(b3[1]), int(b3[2]), hot.lerp(Color(0.62, 0.64, 0.68), smoothstep(0.6, 1.0, t))])
	var mm: MultiMesh = _atoms_mm.multimesh
	if mm.instance_count != ats.size():
		mm.instance_count = ats.size()
	for i in ats.size():
		var r := atom_r(str(ats[i][1]))
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * r), ats[i][0]))
		mm.set_instance_color(i, atom_color(str(ats[i][1])))
	var bm: MultiMesh = _bonds_mm.multimesh
	var nb := 0
	for b4 in bds:
		var pa: Vector3 = ats[int(b4[0])][0]
		var pb: Vector3 = ats[int(b4[1])][0]
		if pa.distance_to(pb) > 3.2:
			continue   # a bond pulled too far apart has broken
		nb += 1
	if bm.instance_count != nb:
		bm.instance_count = nb
	var k := 0
	for b5 in bds:
		var a: Vector3 = ats[int(b5[0])][0]
		var b: Vector3 = ats[int(b5[1])][0]
		var d := b - a
		var l := d.length()
		if l > 3.2:
			continue
		var y := d / maxf(l, 1e-5)
		var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		var rad := 0.09 * sqrt(float(b5[2]))
		bm.set_instance_transform(k, Transform3D(Basis(x * rad, y * l, z * rad), (a + b) * 0.5))
		bm.set_instance_color(k, b5[3])
		k += 1


## For the harness: what is in the lens.
func debug_state() -> Dictionary:
	var by := {}
	for m in _mols:
		var key := "%s@%s" % [m["sp"], m["region"]]
		by[key] = int(by.get(key, 0)) + 1
	return {"cv": cv, "molecules": _mols.size(), "by": by, "stories": _stories.size(), "shown_stories": shown_stories,
		"atoms": _atoms_mm.multimesh.instance_count, "bonds": _bonds_mm.multimesh.instance_count}

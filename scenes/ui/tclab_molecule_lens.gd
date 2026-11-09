extends PanelContainer

## The TC Process Lab's molecule lens: a picture-in-picture over the studio
## that shows ONE worked example of the main reaction going on in the
## selected volume, drawn as a bold ball-and-stick figure (dark carbon, red
## oxygen, pale hydrogen, light sticks — a textbook plate).
##
## It asks the running TcProcSim what is reacting there (drying, boiling,
## condensing, pyrolysis, tar cracking, burning) and plays that reaction's
## storyboard (TcMolecules.stories) as a loop:
##   before      the reactant, named
##   bonds break the bonds that will go heat up and shake
##   after       the atoms move into the products (every atom is kept:
##               the storyboards balance), which are named; gases drift off
## For a wood charge the pyrolysis example follows what the bed is doing:
## hemicellulose first (it goes at the lowest temperature), then cellulose,
## then lignin, with charring in turn — picked from each component's rate in
## the bed's own cells. With nothing reacting it shows what the volume
## holds: its main molecules, side by side, with their shares.
##
## Earlier this lens simulated ~60 molecules flying round a box; that read
## as noise. It is a figure now, not a simulation: moles are not simulated,
## the picture follows the model's numbers. It moves on the lab's clock
## (frozen while the lab is paused) and costs nothing while closed (the
## panel frees it).

const VIEW_SIZE := Vector2i(440, 320)
## How the atoms are drawn (Å): big balls on thin sticks.
const LOOK := {
	"H": {"color": Color(0.93, 0.91, 0.84), "r": 0.33},
	"C": {"color": Color(0.07, 0.07, 0.075), "r": 0.46},
	"O": {"color": Color(0.80, 0.05, 0.04), "r": 0.44},
	"N": {"color": Color(0.18, 0.32, 0.86), "r": 0.44},
}
const STICK_R := 0.085
const STICK_COLOR := Color(0.72, 0.71, 0.67)
const HOT := Color(1.0, 0.50, 0.08)
const BACKDROP := Color(0.91, 0.92, 0.93)
const INK := Color(0.10, 0.11, 0.13)
## The loop (seconds of lens time).
const T_SHOW := 1.7
const T_BREAK := 0.9
const T_MOVE := 1.9
const T_HOLD := 2.8
const T_FADE := 0.45
const DRIFT := 1.3                # how far a freed gas molecule drifts, Å
const RATE_EPS := 1.0e-8          # mol/s: below this a reaction is not shown
const IDLE_CHECK_S := 1.0
const KIND_ORDER := ["pyrolysis", "cracking", "combustion", "drying", "boiling", "condensing"]
const MAX_LABELS := 8

var sim: TcProcSim = null
var cv := -1
var title_label: Label
var caption: Label
var legend: Label
var viewport: SubViewport
var close_requested: Callable = Callable()
var shown_stories := 0            # for the harness

var _world: Node3D
var _cam: Camera3D
var _atoms_mm: MultiMeshInstance3D
var _bonds_mm: MultiMeshInstance3D
var _overlay: Control
var _svc: SubViewportContainer
var _phase_label: Label
var _story_label: Label
var _labels: Array = []
var _scene := {}                  # the prepared storyboard (see _prepare)
var _t := 0.0
var _spin := 0.0
var _seq := 0
var _idle_acc := 0.0
var _n_atoms := 0
var _n_bonds := 0


func _init() -> void:
	name = "MoleculeLens"
	add_theme_stylebox_override("panel", UITheme.card_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
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
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(VIEW_SIZE)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.clip_contents = true
	v.add_child(stack)
	_svc = SubViewportContainer.new()
	_svc.stretch = true
	_svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_svc)
	viewport = SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_svc.add_child(viewport)
	_build_world()
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_overlay)
	_story_label = _ink_label(UITheme.FONT_SM, true)
	_story_label.position = Vector2(8, 5)
	_story_label.size = Vector2(VIEW_SIZE.x - 110, 20)
	_story_label.clip_text = true
	_story_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_overlay.add_child(_story_label)
	_phase_label = _ink_label(UITheme.FONT_XS, true)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_phase_label.position = Vector2(VIEW_SIZE.x - 108, 7)
	_phase_label.size = Vector2(100, 18)
	_overlay.add_child(_phase_label)
	for _i in MAX_LABELS:
		var l := _ink_label(UITheme.FONT_XS, false)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.size = Vector2(150, 30)
		l.visible = false
		_overlay.add_child(l)
		_labels.append(l)
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


func _ink_label(size: int, bold: bool) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", INK)
	if bold:
		l.add_theme_font_override("font", UITheme.font("semibold"))
	return l


func _build_world() -> void:
	_world = Node3D.new()
	viewport.add_child(_world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = BACKDROP
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.86, 0.88, 0.92)
	e.ambient_light_energy = 0.42
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	_world.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 28, 0)
	key.light_energy = 0.95
	_world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, -140, 0)
	fill.light_energy = 0.18
	_world.add_child(fill)
	_cam = Camera3D.new()
	_cam.fov = 28.0
	_cam.position = Vector3(0, 0, 30)
	_world.add_child(_cam)
	_cam.current = true
	_atoms_mm = _multimesh(_sphere(), 0.38, 0.35)
	_bonds_mm = _multimesh(_cylinder(), 0.6, 0.2)


func _sphere() -> Mesh:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = 28
	s.rings = 14
	return s


func _cylinder() -> Mesh:
	var c := CylinderMesh.new()
	c.top_radius = 1.0
	c.bottom_radius = 1.0
	c.height = 1.0
	c.radial_segments = 10
	c.rings = 1
	return c


func _multimesh(mesh: Mesh, rough: float, spec: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.custom_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 80, 80))
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = rough
	m.metallic_specular = spec
	mi.material_override = m
	_world.add_child(mi)
	return mi


# ---------------------------------------------------------------------------
# Following the model
# ---------------------------------------------------------------------------

## Point the lens at a volume (starts its example again).
func show_cv(s: TcProcSim, i: int) -> void:
	sim = s
	cv = i
	_seq = 0
	_scene = {}
	_next()


## Each frame from the panel. running: the lab clock moves; rate: lab
## seconds per real second.
func update_lens(delta: float, running: bool, rate: float) -> void:
	if sim == null or cv < 0 or cv >= sim.n_cv:
		return
	var mult := clampf(sqrt(maxf(rate, 0.0)) / 6.0, 0.6, 1.4) if running else 0.0
	var dt := delta * mult
	_spin += dt
	if _scene.is_empty():
		_next()
	if bool(_scene.get("idle", false)):
		# Nothing was reacting: look again now and then.
		_idle_acc += delta
		if _idle_acc >= IDLE_CHECK_S:
			_idle_acc = 0.0
			if not _candidates().is_empty() or _idle_key() != str(_scene.get("key", "")):
				_next()
			else:
				_refresh_text()
	else:
		_t += dt
		if _t >= T_SHOW + T_BREAK + T_MOVE + T_HOLD + T_FADE:
			_next()
	_draw_all()


func _cv_t() -> float:
	return sim.gas_t(cv)


func _is_bed_cv() -> bool:
	return cv == sim.vessel_cv and sim.bed != null and not sim.bed.is_empty()


## How fast each wood component is breaking down in the bed right now
## (kg/s): each dry cell's mass times its own first-step rate constant
## (Miller & Bellan, the model's kinetics).
func wood_rates() -> Dictionary:
	var out := {"hemicellulose": 0.0, "cellulose": 0.0, "lignin": 0.0}
	if not _is_bed_cv() or sim.bed.plastic != "":
		return out
	var keys := {"hemicellulose": "hem", "cellulose": "cel", "lignin": "lig"}
	for d in sim.bed.domains:
		for i in int(d["n"]):
			if float(d["mw"][i]) > 1e-6:
				continue
			var t := float(d["T"][i])
			if t < TcBed.MIN_REACT_K:
				continue
			for comp in keys.keys():
				var p: Array = TcReactions.WOOD[comp]
				out[comp] = float(out[comp]) + float(d[keys[comp]][i]) * TcReactions.arrhenius(float(p[0]), float(p[1]), t)
	return out


## The storyboards worth showing now, the most telling first.
func _candidates() -> Array:
	var out: Array = []
	if cv >= sim.react_rate.size():
		return out
	var rr: Dictionary = sim.react_rate[cv]
	var all := TcMolecules.stories()
	for kind in KIND_ORDER:
		if float(rr.get(kind, 0.0)) <= RATE_EPS:
			continue
		if kind == "pyrolysis":
			if _is_bed_cv() and sim.bed.plastic != "":
				out.append_array(all["plastic"])
				continue
			var wr := wood_rates()
			var comps: Array = wr.keys()
			comps.sort_custom(func(a, b) -> bool: return float(wr[a]) > float(wr[b]))
			var top := float(wr[comps[0]])
			var by_id := {}
			for st in all["pyrolysis"]:
				by_id[str(st["id"])] = st
			# The component reacting fastest, then charring, then any other
			# component doing at least a sixth as much.
			out.append(by_id[str(comps[0])] if top > 0.0 else by_id["hemicellulose"])
			out.append(by_id["charring"])
			for k in range(1, comps.size()):
				if top > 0.0 and float(wr[comps[k]]) >= top / 6.0:
					out.append(by_id[str(comps[k])])
		elif all.has(kind):
			out.append_array(all[kind])
	return out


func _next() -> void:
	if sim == null or cv < 0 or cv >= sim.n_cv:
		return
	var c := _candidates()
	_t = 0.0
	_idle_acc = 0.0
	if c.is_empty():
		_scene = _prepare_idle()
	else:
		_scene = _prepare(c[_seq % c.size()])
		_seq += 1
		shown_stories += 1
	_frame_camera()
	_refresh_text()


## What "*" stands for here: the volume's main liquid, or its main
## condensable vapour.
func _wild(region: String) -> String:
	var best := "H2O"
	var bv := 0.0
	var src: PackedFloat64Array = sim.liq[cv] if region == "liquid" else sim.gas[cv]
	for s in TcProcSim.COND:
		var sp := str(TcProcSim.SP[s])
		if src[s] > bv and not TcMolecules.layout(sp).is_empty():
			bv = src[s]
			best = sp
	return best


## A storyboard made ready to draw:
##   atoms   [[element, from, to, drift]] (stage Å)
##   keep / gone / made   bonds [[i, j, order]] present throughout, only
##           before, only after
##   tags_from / tags_to  [[text, anchor, drift]] name tags under molecules
func _prepare(st: Dictionary) -> Dictionary:
	var atoms: Array = []
	var bonds_from := {}
	var tags_from: Array = []
	var same := ""
	for f in st["from"]:
		var sp := str(f[0])
		if sp == "*":
			sp = _wild(str(f[1]))
			same = sp
		var lay := TcMolecules.layout(sp)
		var base := atoms.size()
		var c: Vector3 = f[2]
		for a in lay.get("atoms", []):
			atoms.append([str(a[0]), c + (a[1] as Vector3), Vector3.ZERO, Vector3.ZERO, false])
		for b in lay.get("bonds", []):
			bonds_from[_pair(base + int(b[0]), base + int(b[1]))] = int(b[2])
		tags_from.append([sp, c, Vector3.ZERO, _low(lay, c)])
	var bonds_to := {}
	var tags_to: Array = []
	for t in st["to"]:
		var sp2 := str(t[0])
		if sp2 == "=":
			sp2 = same
		var lay2 := TcMolecules.layout(sp2)
		var c2: Vector3 = t[2]
		var drift := Vector3.ZERO
		if str(t[1]) == "gas":
			drift = (c2 if c2.length() > 0.5 else Vector3.UP).normalized() * DRIFT
			drift.z = 0.0
		var idx: Array = []
		for a2 in lay2.get("atoms", []):
			var target: Vector3 = c2 + (a2[1] as Vector3)
			var best := -1
			var bd := INF
			for ai in atoms.size():
				var at: Array = atoms[ai]
				if bool(at[4]) or str(at[0]) != str(a2[0]):
					continue
				var d := (at[1] as Vector3).distance_squared_to(target)
				if d < bd:
					bd = d
					best = ai
			if best < 0:
				# An unbalanced storyboard would land here (the selftest keeps
				# them balanced): the atom appears in place.
				atoms.append([str(a2[0]), target, target, drift, true])
				best = atoms.size() - 1
			else:
				atoms[best][2] = target
				atoms[best][3] = drift
				atoms[best][4] = true
			idx.append(best)
		for b2 in lay2.get("bonds", []):
			bonds_to[_pair(int(idx[int(b2[0])]), int(idx[int(b2[1])]))] = int(b2[2])
		tags_to.append([sp2, c2, drift, _low(lay2, c2)])
	for at2 in atoms:
		if not bool(at2[4]):
			at2[2] = at2[1]
	var keep: Array = []
	var gone: Array = []
	var made: Array = []
	for k in bonds_from.keys():
		var pr: Vector2i = k
		if bonds_to.has(k):
			keep.append([pr.x, pr.y, int(bonds_to[k])])
		else:
			gone.append([pr.x, pr.y, int(bonds_from[k])])
	for k2 in bonds_to.keys():
		if not bonds_from.has(k2):
			var pr2: Vector2i = k2
			made.append([pr2.x, pr2.y, int(bonds_to[k2])])
	# Atoms on a bond that breaks shake before it goes.
	var shaky := {}
	for g in gone:
		shaky[int(g[0])] = true
		shaky[int(g[1])] = true
	return {"id": str(st["id"]), "title": str(st["title"]), "text": str(st["text"]), "atoms": atoms,
		"keep": keep, "gone": gone, "made": made, "shaky": shaky,
		"tags_from": _merge_tags(tags_from), "tags_to": _merge_tags(tags_to), "idle": false}


static func _pair(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


## The lowest point of a molecule standing at `c` (its name goes under it).
static func _low(lay: Dictionary, c: Vector3) -> float:
	var y := 0.0
	for a in lay.get("atoms", []):
		y = minf(y, (a[1] as Vector3).y)
	return c.y + y - 0.75


## One tag per species: the first molecule carries the name and the count.
func _merge_tags(tags: Array) -> Array:
	var out: Array = []
	var at := {}
	for t in tags:
		var sp := str(t[0])
		if at.has(sp):
			out[int(at[sp])][4] = int(out[int(at[sp])][4]) + 1
			continue
		at[sp] = out.size()
		out.append([sp, Vector3((t[1] as Vector3).x, float(t[3]), (t[1] as Vector3).z), t[2], "", 1])
	for o in out:
		var n := int(o[4])
		o[3] = "%s%s\n%s" % [("%d × " % n) if n > 1 else "", _short_name(str(o[0])), TcMolecules.formula(str(o[0]))]
	return out


static func _short_name(sp: String) -> String:
	var n := TcMolecules.display_name(sp)
	if sp == "tar":
		return "Levoglucosan (tar)"
	return n


## Nothing reacting: what the volume holds, side by side.
func _idle_species() -> Array:
	var out: Array = []     # [[species, share, what]]
	if _is_bed_cv():
		var t := sim.bed.totals()
		var parts := {}
		if sim.bed.plastic != "":
			parts["alkane:10"] = float(t["plastic_kg"])
		else:
			var wood := float(t["wood_kg"])
			var fd: Dictionary = (TcProcSpec.FEEDS.get(sim.bed.feed, {}) as Dictionary).get("solid", {})
			parts["cellulose2"] = wood * float(fd.get("cellulose", 0.42))
			parts["lignin"] = wood * float(fd.get("lignin", 0.28))
			parts["char"] = float(t["char_kg"])
		var tot := 0.0
		for k in parts.keys():
			tot += float(parts[k])
		var ks: Array = parts.keys()
		ks.sort_custom(func(a, b) -> bool: return float(parts[a]) > float(parts[b]))
		for k2 in ks:
			if tot > 0.0 and float(parts[k2]) / tot > 0.04 and out.size() < 2:
				out.append([str(k2), float(parts[k2]) / tot, "of the charge"])
	var g: PackedFloat64Array = sim.gas[cv]
	var n := 0.0
	for s in g.size():
		n += g[s]
	var order: Array = []
	for s2 in g.size():
		if n > 0.0 and g[s2] / n > 0.04 and not TcMolecules.layout(str(TcProcSim.SP[s2])).is_empty():
			order.append(s2)
	order.sort_custom(func(a: int, b: int) -> bool: return g[a] > g[b])
	for s3 in order:
		if out.size() >= 3:
			break
		out.append([str(TcProcSim.SP[s3]), g[s3] / n, "of the gas"])
	return out


func _idle_key() -> String:
	var k := PackedStringArray()
	for e in _idle_species():
		k.append(str(e[0]))
	return ",".join(k)


func _prepare_idle() -> Dictionary:
	var list := _idle_species()
	var atoms: Array = []
	var keep: Array = []
	var tags: Array = []
	var x := 0.0
	var key := PackedStringArray()
	for e in list:
		var sp := str(e[0])
		key.append(sp)
		var lay := TcMolecules.layout(sp)
		var half := 0.0
		for a in lay.get("atoms", []):
			half = maxf(half, absf((a[1] as Vector3).x))
		half += 1.2
		var c := Vector3(x + half, 0.0, 0.0)
		var base := atoms.size()
		for a2 in lay.get("atoms", []):
			atoms.append([str(a2[0]), c + (a2[1] as Vector3), c + (a2[1] as Vector3), Vector3.ZERO, true])
		for b in lay.get("bonds", []):
			keep.append([base + int(b[0]), base + int(b[1]), int(b[2])])
		tags.append([sp, Vector3(c.x, _low(lay, c), 0.0), Vector3.ZERO,
			"%s\n%s · %.0f %% %s" % [_short_name(sp), TcMolecules.formula(sp), float(e[1]) * 100.0, str(e[2])], 1])
		x += half * 2.0
	# Centre the row.
	for at in atoms:
		at[1] = (at[1] as Vector3) - Vector3(x * 0.5, 0, 0)
		at[2] = at[1]
	for t in tags:
		t[1] = (t[1] as Vector3) - Vector3(x * 0.5, 0, 0)
	return {"id": "idle", "title": "What is in here", "idle": true, "key": ",".join(key),
		"text": "Nothing is reacting in this volume right now. These are the main molecules it holds." if not list.is_empty()
			else "Nothing to show here yet.",
		"atoms": atoms, "keep": keep, "gone": [], "made": [], "shaky": {}, "tags_from": tags, "tags_to": []}


## Stand the camera back far enough to hold the whole example, before and after.
func _frame_camera() -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for a in _scene.get("atoms", []):
		for p in [a[1] as Vector3, (a[2] as Vector3) + (a[3] as Vector3)]:
			lo = lo.min(p)
			hi = hi.max(p)
	if not is_finite(lo.x):
		lo = Vector3(-3, -3, 0)
		hi = Vector3(3, 3, 0)
	var c := (lo + hi) * 0.5
	var hx := (hi.x - lo.x) * 0.5 + 1.6
	# Room for the name tags under the molecules and the title above.
	var hy := (hi.y - lo.y) * 0.5 + 2.6
	var th := tan(deg_to_rad(_cam.fov * 0.5))
	var aspect := float(VIEW_SIZE.x) / float(VIEW_SIZE.y)
	var dist := maxf(hy / th, hx / (th * aspect)) + 2.0
	_cam.position = Vector3(c.x, c.y - 0.5, dist)
	_cam.rotation = Vector3.ZERO
	_cam.near = 0.5
	_cam.far = dist + 60.0


func _refresh_text() -> void:
	var name_cv := str(sim.net["cvs"][cv].get("label", "volume"))
	title_label.text = "Molecules in %s · %.0f °C" % [name_cv, _cv_t() - 273.15]
	_story_label.text = str(_scene.get("title", ""))
	caption.text = str(_scene.get("text", ""))
	var bits: Array = []
	if _is_bed_cv() and sim.bed.plastic == "":
		var wr := wood_rates()
		var tot := 0.0
		for k in wr.keys():
			tot += float(wr[k])
		if tot > 1e-12:
			var parts: Array = []
			for k2 in ["hemicellulose", "cellulose", "lignin"]:
				if float(wr[k2]) / tot >= 0.01:
					parts.append("%s %.0f %%" % [k2, float(wr[k2]) / tot * 100.0])
			bits.append("Breaking down now: " + ", ".join(parts))
	var g: PackedFloat64Array = sim.gas[cv]
	var n := 0.0
	for s in g.size():
		n += g[s]
	if n > 0.0:
		var order: Array = []
		for s2 in g.size():
			if g[s2] / n >= 0.01:
				order.append(s2)
		order.sort_custom(func(a: int, b: int) -> bool: return g[a] > g[b])
		var gp: Array = []
		for s3 in order.slice(0, 4):
			gp.append("%s %.0f %%" % [TcMolecules.display_name(str(TcProcSim.SP[s3])).to_lower(), g[s3] / n * 100.0])
		bits.append("Gas here: " + ", ".join(gp))
	legend.text = " · ".join(bits)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

static func atom_color(el: String) -> Color:
	if LOOK.has(el):
		return LOOK[el]["color"]
	return (TcSpecies.ATOMS.get(el, {"color": Color.GRAY}) as Dictionary)["color"]


static func atom_r(el: String) -> float:
	if LOOK.has(el):
		return float(LOOK[el]["r"])
	return float((TcSpecies.ATOMS.get(el, {"r": 0.6}) as Dictionary)["r"]) * 0.6


func _draw_all() -> void:
	var idle := bool(_scene.get("idle", false))
	var t := _t
	var b0 := T_SHOW
	var b1 := T_SHOW + T_BREAK
	var b2 := b1 + T_MOVE
	var b3 := b2 + T_HOLD
	var u := 0.0 if idle else smoothstep(b1, b2, t)
	var freed := 0.0 if idle else smoothstep(b2 - 0.2, b3, t)
	var heat := 0.0 if idle else smoothstep(b0 * 0.6, b1, t) * (1.0 - smoothstep(b1, b1 + T_MOVE * 0.35, t))
	# A slow rock about the upright axis, so the balls read as round.
	var rock := Basis(Vector3.UP, sin(_spin * 0.7) * 0.16) * Basis(Vector3.RIGHT, sin(_spin * 0.45) * 0.07)
	var atoms: Array = _scene.get("atoms", [])
	var shaky: Dictionary = _scene.get("shaky", {})
	var pos := PackedVector3Array()
	pos.resize(atoms.size())
	for i in atoms.size():
		var a: Array = atoms[i]
		var p: Vector3 = (a[1] as Vector3).lerp(a[2] as Vector3, u) + (a[3] as Vector3) * freed
		if shaky.has(i) and heat > 0.0:
			p += Vector3(sin(t * 47.0 + float(i) * 1.7), cos(t * 53.0 + float(i) * 2.3), 0.0) * 0.07 * heat
		pos[i] = rock * p
	var mm: MultiMesh = _atoms_mm.multimesh
	if mm.instance_count != atoms.size():
		mm.instance_count = atoms.size()
	for i2 in atoms.size():
		var el := str(atoms[i2][0])
		mm.set_instance_transform(i2, Transform3D(Basis.from_scale(Vector3.ONE * atom_r(el)), pos[i2]))
		mm.set_instance_color(i2, atom_color(el))
	_n_atoms = atoms.size()
	# Sticks: [a, b, order, colour].
	var sticks: Array = []
	for k in _scene.get("keep", []):
		sticks.append([int(k[0]), int(k[1]), int(k[2]), STICK_COLOR])
	if u < 0.3:
		for g in _scene.get("gone", []):
			sticks.append([int(g[0]), int(g[1]), int(g[2]), STICK_COLOR.lerp(HOT, heat)])
	if u > 0.8:
		var settle := smoothstep(b2, b2 + 0.9, t)
		for m in _scene.get("made", []):
			sticks.append([int(m[0]), int(m[1]), int(m[2]), HOT.lerp(STICK_COLOR, settle)])
	var xfs: Array = []
	var cols: Array = []
	for s in sticks:
		var pa: Vector3 = pos[int(s[0])]
		var pb: Vector3 = pos[int(s[1])]
		var d := pb - pa
		var l := d.length()
		if l < 1e-4 or l > 3.4:
			continue
		var y := d / l
		var side := y.cross(Vector3(0, 0, 1))
		side = side.normalized() if side.length() > 0.05 else y.cross(Vector3.UP).normalized()
		var z := side.cross(y)
		var order := int(s[2])
		var rad := STICK_R if order == 1 else STICK_R * 0.8
		var offs: Array = [0.0]
		if order == 2:
			offs = [-0.13, 0.13]
		elif order >= 3:
			offs = [-0.19, 0.0, 0.19]
		for o in offs:
			xfs.append(Transform3D(Basis(side * rad, y * l, z * rad), (pa + pb) * 0.5 + side * float(o)))
			cols.append(s[3])
	var bm: MultiMesh = _bonds_mm.multimesh
	if bm.instance_count != xfs.size():
		bm.instance_count = xfs.size()
	for k2 in xfs.size():
		bm.set_instance_transform(k2, xfs[k2])
		bm.set_instance_color(k2, cols[k2])
	_n_bonds = sticks.size()
	# Fade the picture between examples.
	var vis := 1.0
	if not idle:
		vis = smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(b3, b3 + T_FADE, t))
	_svc.modulate = Color(1, 1, 1, 1)
	_atoms_mm.transparency = 1.0 - vis
	_bonds_mm.transparency = 1.0 - vis
	# Name tags and the step.
	var a_from := 1.0 if idle else (1.0 - smoothstep(b0, b1, t)) * smoothstep(0.0, 0.3, t)
	var a_to := 0.0 if idle else smoothstep(b2 - 0.4, b2 + 0.2, t) * (1.0 - smoothstep(b3, b3 + T_FADE, t))
	var li := 0
	for grp in [[_scene.get("tags_from", []), a_from, 0.0], [_scene.get("tags_to", []), a_to, freed]]:
		for tag in grp[0]:
			if li >= _labels.size():
				break
			var lab: Label = _labels[li]
			li += 1
			var wp: Vector3 = rock * ((tag[1] as Vector3) + (tag[2] as Vector3) * float(grp[2]))
			var sp := _cam.unproject_position(wp)
			lab.text = str(tag[3])
			lab.visible = float(grp[1]) > 0.02
			lab.modulate = Color(1, 1, 1, float(grp[1]))
			lab.position = Vector2(clampf(sp.x - lab.size.x * 0.5, 2.0, VIEW_SIZE.x - lab.size.x - 2.0),
				clampf(sp.y, 26.0, VIEW_SIZE.y - 32.0))
	for k3 in range(li, _labels.size()):
		(_labels[k3] as Label).visible = false
	if idle:
		_phase_label.text = ""
	elif t < b0:
		_phase_label.text = "1 · Before"
	elif t < b1 + T_MOVE * 0.3:
		_phase_label.text = "2 · Bonds break"
	else:
		_phase_label.text = "3 · After"


## For the harness: what the lens is showing.
func debug_state() -> Dictionary:
	var tags := 0
	for l in _labels:
		if (l as Label).visible:
			tags += 1
	return {"cv": cv, "story": str(_scene.get("id", "")), "title": str(_scene.get("title", "")),
		"idle": bool(_scene.get("idle", false)), "t": _t, "shown_stories": shown_stories,
		"atoms": _n_atoms, "bonds": _n_bonds, "tags": tags, "phase": _phase_label.text,
		"ball_r": atom_r("C"), "stick_r": STICK_R, "gone": (_scene.get("gone", []) as Array).size(),
		"made": (_scene.get("made", []) as Array).size()}

class_name CspLabBuilder
extends Node3D

## A concentrator from the designer, built in 3D: the optic (paraboloid,
## parabolic cylinder, mirror rows, heliostats, lens, sphere, water lens,
## Fresnel sheet), its receiver, the structure (CspLabStructure's members)
## and the tracking: `set_sun(s)` turns it to face a world sun the way its
## mount would (CspLabSite.pose). Optional overlays: traced rays and the
## tracking axes with their names.
##
## Nodes: Base (ground-fixed members) · Stage (the first moving stage, at
## the pivot) › Optic (the optic frame) › Content (the optic, the receiver
## and the members that move with it, at −pivot) · or, for a ground-fixed
## field, Field (the mirrors as ONE MultiMesh of a heliostat / row, re-aimed
## per sun by rewriting their transforms, never re-meshed; the receiver) ·
## Rays · Axes.
##
## Mirrors: every concentrator in the world draws with ONE shared mirror
## material whose sun the runtimes push at most twice a second
## (`push_world_sun`, change-gated); the designer's studio has its own sun
## and asks for a private copy (`private_mirror`).
##
## Every triangle goes through `_tri`, which winds it clockwise seen from
## its normal (Godot's front face) — the pallet rack was once built inside
## out, lit from behind.

const MODEL_ID := "csplab_concentrator"
const _MIRROR_SHADER := preload("res://core/csplab/csplab_mirror.gdshader")
const _GLOW_SHADER := preload("res://gameplay/csp_focal_glow.gdshader")
## The receiver's glow at full working flux (the GLB trough's numbers): the
## material's emission, a real light round it, and additive glow cards — the
## daytime bloom is kept tight, so a bright surface alone reads flat.
const GLOW_EMISSION_PEAK := 24.0
const GLOW_LIGHT_PEAK := 9.0
const GLOW_CARD_PEAK := 14.0
const GLOW_GAMMA := 0.6

var spec: Dictionary = {}
var design: Dictionary = {}
var lat := 35.0
var sun := Vector3(0, 1, 0)
var show_rays := false
var show_axes := false
var show_structure := true
## The designer shows where the sun is: a disc out along its direction.
var show_sun_marker := false
var last_pose: Dictionary = {}

var _base: Node3D
var _stage: Node3D
var _optic: Node3D
var _content: Node3D
var _field: Node3D
## A field's mirrors: one MultiMesh instance per heliostat / row.
var _field_mm: MultiMeshInstance3D
## A private copy of the mirror material (the studio's own sun); the world
## shares one.
var private_mirror := false
## Bumped when the pose moves (readers re-derive the drive angles then).
var pose_serial := 0
## A level water lens's receiver, its stand and glow, carried into the spot.
var _cart: Node3D = null
var _rays: MeshInstance3D
var _axes: Node3D
var _receiver_mats: Array = []
## This concentrator's own copy of the mirror material (its sun uniforms).
var _mirror_mat: ShaderMaterial = null
## The receiver's glow: lights and additive cards, and how hot it is now.
var _glow_lights: Array = []
var _glow_cards: Array = []
var glow_focus := 0.0
## Every drawn member, for picking: {frame, a, b, r, m}.
var member_segments: Array = []
var _built := false
var _sun_mark: Node3D = null
var _hl: MeshInstance3D = null

static var _mats := {}
## The world's shared mirror material and the sun last pushed to it.
static var _shared_mirror: ShaderMaterial = null
static var _shared_sun := Vector3.ZERO
static var _shared_day := -1.0


static func build_node(sp: Dictionary, node_name: String = "Concentrator", opts: Dictionary = {}) -> CspLabBuilder:
	var b := CspLabBuilder.new()
	b.name = node_name
	b.private_mirror = bool(opts.get("private_mirror", false))
	b.setup(sp, opts)
	return b


func setup(sp: Dictionary, opts: Dictionary = {}) -> void:
	spec = CspLabSpec.resolve(sp)
	lat = CspLabDesign.lat_of(spec)
	design = CspLabDesign.solve(spec, {"rays": mini(int((spec["trace"] as Dictionary)["rays"]), 3000)})
	sun = opts.get("sun", CspLabSite.design_sun(lat)) as Vector3
	show_structure = bool(opts.get("structure", true))
	_build()


## Rebuild for a new design (the studio), keeping the sun and overlays.
func rebuild(sp: Dictionary, d: Dictionary = {}) -> void:
	spec = CspLabSpec.resolve(sp)
	lat = CspLabDesign.lat_of(spec)
	design = d if not d.is_empty() else CspLabDesign.solve(spec, {"rays": mini(int((spec["trace"] as Dictionary)["rays"]), 3000)})
	_build()


func is_field() -> bool:
	return CspLabSite.is_field(spec)


func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	_receiver_mats.clear()
	_glow_lights.clear()
	_glow_cards.clear()
	_mirror_mat = (_mat("mirror") as ShaderMaterial).duplicate() as ShaderMaterial if private_mirror else shared_mirror()
	_cart = null
	_hl = null
	_sun_mark = null
	var g: Dictionary = design["geo"]
	var st: Dictionary = design["structure"]
	var pivot_w: Vector3 = st.get("pivot_world", Vector3.ZERO)
	var pivot_l: Vector3 = st.get("pivot_local", Vector3.ZERO)
	_base = Node3D.new()
	_base.name = "Base"
	add_child(_base)
	_rays = MeshInstance3D.new()
	_rays.name = "Rays"
	_rays.set_meta("studio_no_frame", true)
	_rays.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rays.material_override = _mat("rays")
	_axes = Node3D.new()
	_axes.name = "Axes"
	_axes.set_meta("studio_no_frame", true)
	add_child(_axes)
	if show_sun_marker:
		_sun_mark = Node3D.new()
		_sun_mark.name = "SunMarker"
		add_child(_sun_mark)
	if is_field():
		_field = Node3D.new()
		_field.name = "Field"
		_field.position = pivot_w
		_field.basis = CspLabSite.field_basis(spec)
		add_child(_field)
		_field_mm = MultiMeshInstance3D.new()
		_field_mm.name = "Mirrors"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _field_unit_mesh(g)
		mm.instance_count = _field_count(g)
		_field_mm.multimesh = mm
		_field.add_child(_field_mm)
		_add_mesh(_field, "Receiver", _receiver_mesh(g), true)
		_add_receiver_glow(_field, g)
		_field.add_child(_rays)
	else:
		_stage = Node3D.new()
		_stage.name = "Stage"
		_stage.position = pivot_w
		add_child(_stage)
		_optic = Node3D.new()
		_optic.name = "Optic"
		_stage.add_child(_optic)
		_content = Node3D.new()
		_content.name = "Content"
		_content.position = -pivot_l
		_optic.add_child(_content)
		_add_optic(g)
		var rec_parent := _content
		if bool(g.get("follow_focus", false)):
			_cart = Node3D.new()
			_cart.name = "ReceiverCart"
			_content.add_child(_cart)
			# The pot is raised on its stand to the smallest spot.
			var lift := Node3D.new()
			lift.name = "ReceiverLift"
			_cart.add_child(lift)
			rec_parent = lift
		_add_mesh(rec_parent, "Receiver", _receiver_mesh(g), true)
		_add_receiver_glow(rec_parent, g)
		_content.add_child(_rays)
	if show_structure:
		_add_members(st)
	_built = true
	set_sun(sun, true)
	_apply_glow()


# ---------------------------------------------------------------------------
# Pose
# ---------------------------------------------------------------------------

## Face the world sun `s` (stowed when it is below the horizon).
func set_sun(s: Vector3, force: bool = false) -> void:
	if not _built:
		sun = s
		return
	if not force and s.distance_to(sun) < 1e-5:
		return
	sun = s
	var p := CspLabSite.pose(spec, s, lat)
	last_pose = p
	if is_field():
		var sl: Vector3 = p["sun_local"]
		if sl.y <= 0.02:
			sl = CspLabDesign.design_sun_local(spec)
		_aim_field(design["geo"] as Dictionary, sl)
	else:
		var stage_b: Basis = p["stage"]
		_stage.basis = stage_b
		_optic.basis = stage_b.transposed() * (p["basis"] as Basis)
		if _cart != null:
			var g2: Dictionary = design["geo"]
			var rc := CspLabOptics.focus_follow(g2, p.get("sun_local", Vector3.UP) as Vector3)
			_cart.position = Vector3(rc.x, 0.0, rc.z)
			(_cart.get_child(0) as Node3D).position = Vector3(0, rc.y, 0)
	if show_axes:
		_build_axes(p)
	else:
		_clear_axes()
	_place_sun_marker()
	pose_serial += 1
	if private_mirror:
		_push_mirror_sun()


## The studio's private mirror: its own sun and daylight.
func _push_mirror_sun() -> void:
	if _mirror_mat == null:
		return
	var sw := sun
	if is_inside_tree():
		sw = (global_transform.basis.orthonormalized() * sun).normalized()
	_mirror_mat.set_shader_parameter("sun_dir", sw)
	_mirror_mat.set_shader_parameter("daylight", DaylightModel.sky_light(clampf(sw.y, -1.0, 1.0)))


## The one mirror material every concentrator in the world draws with.
static func shared_mirror() -> ShaderMaterial:
	if _shared_mirror == null:
		_shared_mirror = (_mat("mirror") as ShaderMaterial).duplicate() as ShaderMaterial
	return _shared_mirror


## The world sun (world direction, toward the sun) on the shared mirror —
## written only when it moved a fifth of a degree or the daylight changed,
## so many runtimes calling it costs nothing.
static func push_world_sun(sw: Vector3) -> void:
	var m := shared_mirror()
	var s := sw.normalized()
	var day := DaylightModel.sky_light(clampf(s.y, -1.0, 1.0))
	if _shared_day >= 0.0 and s.dot(_shared_sun) > 0.999994 and absf(day - _shared_day) < 0.01:
		return
	_shared_sun = s
	_shared_day = day
	m.set_shader_parameter("sun_dir", s)
	m.set_shader_parameter("daylight", day)


## The material the mirrors draw with now (the shared one in the world).
func mirror_material() -> Material:
	return _mirror_mat


## A small sun out along the sun's direction from the pivot, a faint line
## back to the optic — so "it faces the sun" can be seen at a glance.
func _place_sun_marker() -> void:
	if _sun_mark == null:
		return
	for c in _sun_mark.get_children():
		_sun_mark.remove_child(c)
		c.free()
	if sun.y <= 0.0:
		return
	var st: Dictionary = design["structure"]
	var pw: Vector3 = st.get("pivot_world", Vector3.ZERO)
	var bb := frame_aabb()
	var reach := clampf(bb.size.length() * 0.42, 1.2, 120.0)
	if is_field():
		pw = Vector3(0, float((design["geo"] as Dictionary).get("H", 2.0)), 0)
	var at := pw + sun.normalized() * reach
	var disc := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = reach * 0.03
	sm.height = reach * 0.06
	sm.radial_segments = 16
	sm.rings = 8
	disc.mesh = sm
	disc.position = at
	disc.material_override = _mat("sun")
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sun_mark.add_child(disc)
	var line := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var n := 24
	for k in n:
		if k % 2 == 1:
			continue
		im.surface_set_color(Color(1.0, 0.92, 0.45, 0.55))
		im.surface_add_vertex(pw.lerp(at, float(k) / n))
		im.surface_set_color(Color(1.0, 0.92, 0.45, 0.55))
		im.surface_add_vertex(pw.lerp(at, float(k + 1) / n))
	im.surface_end()
	line.mesh = im
	line.material_override = _mat("rays")
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sun_mark.add_child(line)


## Frame name → the node its members hang under.
func _frame_parents() -> Dictionary:
	var opt: Node3D = _content if _content != null else _base
	return {"base": _base, "stage": _stage if _stage != null else _base, "optic": opt,
		"cart": _cart if _cart != null else opt}


## Light one member (from pick_member), or none with {}.
func highlight_member(m: Dictionary) -> void:
	if _hl != null and is_instance_valid(_hl):
		_hl.get_parent().remove_child(_hl)
		_hl.free()
	_hl = null
	if m.is_empty() or not _built:
		return
	var fr := str(m["frame"])
	if is_field():
		fr = "base"
	var parent: Node3D = _base
	if fr == "stage" and _stage != null:
		parent = _stage
	elif fr == "optic" and _content != null:
		parent = _content
	elif fr == "cart":
		parent = _frame_parents()["cart"] as Node3D
	var st := _st("highlight")
	var a: Vector3 = m["a"]
	var b: Vector3 = m["b"]
	if bool(m.get("box", false)):
		var ax := b - a
		var seg_len := maxf(ax.length(), 0.01)
		var y := ax / seg_len if ax.length() > 1e-6 else Vector3.UP
		var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		var z := x.cross(y).normalized()
		_box(st, (a + b) * 0.5, Basis(x, y, z), Vector3(float(m["w"]) * 0.5 + 0.01, seg_len * 0.5 + 0.01, float(m["h"]) * 0.5 + 0.01))
	else:
		_tube(st, a, b, float(m["d"]) * 0.5 + 0.006, 10, true)
	_hl = MeshInstance3D.new()
	_hl.name = "Highlight"
	_hl.mesh = st.commit()
	_hl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(_hl)


func set_overlays(rays: bool, axes: bool) -> void:
	show_rays = rays
	show_axes = axes
	_rays.visible = rays
	if axes:
		_build_axes(last_pose if not last_pose.is_empty() else CspLabSite.pose(spec, sun, lat))
	else:
		_clear_axes()


## Rays (CspLabOptics paths, in the optic frame) drawn as lines.
func set_rays(paths: Array) -> void:
	var im := ImmediateMesh.new()
	var mirror := str(CspLabSpec.OPTIC[str(spec["type"])]) == "mirror"
	var any := false
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for pv in paths:
		var p: Dictionary = pv
		var pts: PackedVector3Array = p["pts"]
		if pts.size() < 2:
			continue
		var fate := str(p["fate"])
		var band := int(p["band"])
		var bc: Color = (CspLabParts.band(band)["color"] as Color)
		for k in pts.size() - 1:
			var c: Color
			if k == 0:
				c = Color(1.0, 0.95, 0.6, 0.35)
			elif fate == "captured":
				c = Color(1.0, 0.62, 0.15, 0.8) if mirror else Color(bc.r, bc.g, bc.b, 0.8)
			elif fate == "shaded" or fate == "blocked":
				c = Color(0.55, 0.55, 0.6, 0.6)
			elif fate == "end":
				c = Color(0.95, 0.3, 0.85, 0.75)
			else:
				c = Color(1.0, 0.2, 0.15, 0.7)
			im.surface_set_color(c)
			im.surface_add_vertex(pts[k])
			im.surface_set_color(c)
			im.surface_add_vertex(pts[k + 1])
			any = true
	if not any:
		im.surface_set_color(Color(0, 0, 0, 0))
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3.ZERO)
	im.surface_end()
	_rays.mesh = im
	_rays.visible = show_rays


## How hot the receiver looks, from the flux on it now (suns). Full glow at
## the design's own flux; a concentrator turned away, under cloud or at
## night goes dark.
func set_glow(suns: float) -> void:
	set_glow_focus(suns / maxf(float(design.get("suns_mean", 1.0)), 1.0))


## How many glow cards light the receiver (a line focus has many, drawn as
## one MultiMesh).
func glow_card_count() -> int:
	var n := 0
	for c in _glow_cards:
		n += int((c as Node).get_meta("glow_cards", 1))
	return n


## 0 = no light on the receiver, 1 = the design's working flux.
func set_glow_focus(f: float) -> void:
	f = clampf(f, 0.0, 1.3)
	if absf(f - glow_focus) < 0.004:
		return
	glow_focus = f
	_apply_glow()


func _apply_glow() -> void:
	# A 30x trough glows less fiercely than a 2000x dish.
	var c_mean := maxf(float(design.get("C_mean", 10.0)), 1.0)
	var cscale := lerpf(0.5, 1.0, clampf(log(c_mean) / log(10.0) / 3.0, 0.0, 1.0))
	var k := pow(glow_focus, GLOW_GAMMA) * cscale
	# Below a few percent of its working flux nothing reads as glowing.
	if glow_focus < 0.04:
		k = 0.0
	var hot := Color(1.0, 0.55, 0.2).lerp(Color(1.0, 0.95, 0.85), clampf(k, 0.0, 1.0))
	for m in _receiver_mats:
		var sm := m as StandardMaterial3D
		sm.emission = hot
		sm.emission_energy_multiplier = GLOW_EMISSION_PEAK * k
	for l in _glow_lights:
		var ol := l as OmniLight3D
		ol.light_energy = GLOW_LIGHT_PEAK * k
		ol.light_color = hot
		ol.visible = k > 0.01
	for c in _glow_cards:
		var gi := c as GeometryInstance3D
		var cm := gi.material_override as ShaderMaterial
		cm.set_shader_parameter("brightness", GLOW_CARD_PEAK * k * float(gi.get_meta("glow_share", 1.0)))
		cm.set_shader_parameter("tint", Vector3(hot.r, hot.g, hot.b))
		gi.visible = k > 0.01


## A light and glow cards on the receiver: one at a point focus, a row of
## them along a line focus, one on a tower's panel.
func _add_receiver_glow(parent: Node3D, g: Dictionary) -> void:
	var t := str(g["type"])
	var size := float(g["size"])
	var pts: Array = []
	var card := 0.3
	var reach := 3.0
	match t:
		"tower":
			var aim: Vector3 = g["aim"]
			pts = [aim + (g.get("panel_n", Vector3.ZERO) as Vector3) * 0.1]
			card = clampf(maxf(float(g["panel_w"]), float(g["panel_h"])) * 1.4, 0.6, 8.0)
			reach = clampf(card * 3.0, 4.0, 30.0)
		"parabolic_trough", "linear_fresnel":
			var L := float(g["length"])
			var y := float(g["rec_y"])
			if t == "parabolic_trough" and bool(g.get("cpc", false)) and str(g["rec_kind"]) != "tube":
				y = 0.0
			# Small cards packed close so they merge into one hot line (spaced
			# a card apart they read as a string of pearls).
			card = clampf(size * 4.0, 0.1, 0.35)
			var n := clampi(int(ceil(L / maxf(card * 0.3, 0.04))), 2, 96)
			for i in n:
				pts.append(Vector3(0, y, lerpf(-L * 0.5, L * 0.5, (float(i) + 0.5) / float(n))))
			reach = clampf(L / 3.0 + 1.0, 1.5, 6.0)
		_:
			pts = [Vector3(0, float(g["rec_y"]), 0)]
			card = clampf(size * 3.0, 0.12, 2.5)
			reach = clampf(card * 6.0, 1.5, 8.0)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	if pts.size() > 2:
		# A line focus: the cards are ONE MultiMesh — one draw call and one
		# material to brighten, however long the tube. Overlapping cards add
		# up, so each takes a share of the brightness.
		var cml := ShaderMaterial.new()
		cml.shader = _GLOW_SHADER
		cml.set_shader_parameter("world_size", card)
		cml.set_shader_parameter("brightness", 0.0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = quad
		mm.instance_count = pts.size()
		for i in pts.size():
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, pts[i] as Vector3))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "ReceiverGlow"
		mmi.multimesh = mm
		mmi.material_override = cml
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		mmi.set_meta("glow_share", 0.35)
		mmi.set_meta("glow_cards", pts.size())
		parent.add_child(mmi)
		_glow_cards.append(mmi)
	else:
		for i in pts.size():
			var cm := ShaderMaterial.new()
			cm.shader = _GLOW_SHADER
			cm.set_shader_parameter("world_size", card)
			cm.set_shader_parameter("brightness", 0.0)
			var mi := MeshInstance3D.new()
			mi.name = "ReceiverGlow%d" % i
			mi.mesh = quad
			mi.material_override = cm
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = pts[i] as Vector3
			mi.visible = false
			mi.set_meta("glow_share", 1.0)
			mi.set_meta("glow_cards", 1)
			parent.add_child(mi)
			_glow_cards.append(mi)
	# A few lights spread along it (one at a point focus).
	var nl := 1 if pts.size() <= 2 else 3
	for j in nl:
		var idx := 0 if nl == 1 else int(round(float(j) / float(nl - 1) * float(pts.size() - 1)))
		var ol := OmniLight3D.new()
		ol.name = "ReceiverLight%d" % j
		ol.position = pts[idx] as Vector3
		ol.omni_range = reach
		ol.omni_attenuation = 1.2
		ol.shadow_enabled = false
		ol.light_bake_mode = Light3D.BAKE_DISABLED
		ol.light_specular = 0.3
		ol.light_volumetric_fog_energy = 0.0
		ol.distance_fade_enabled = true
		ol.distance_fade_begin = reach * 6.0
		ol.distance_fade_length = reach * 3.0
		ol.visible = false
		parent.add_child(ol)
		_glow_lights.append(ol)


## A bounding box for framing (world, relative to this node).
func frame_aabb() -> AABB:
	var g: Dictionary = design["geo"]
	var st: Dictionary = design["structure"]
	var t := str(spec["type"])
	var pw: Vector3 = st.get("pivot_world", Vector3.ZERO)
	match t:
		"tower":
			var r := float(g["field_r"]) + 2.0
			return AABB(Vector3(-r, 0, -r), Vector3(r * 2.0, float(g["H"]) + 2.0, r * 2.0))
		"linear_fresnel":
			var w := float(g["total"]) * 0.5 + 0.6
			var L := float(g["length"]) * 0.5
			var fb := CspLabSite.field_basis(spec)
			var ext := (fb * Vector3(w, 0, L)).abs()
			return AABB(Vector3(-ext.x, 0, -ext.z), Vector3(ext.x * 2.0, float(g["H"]) + 1.2, ext.z * 2.0))
		"parabolic_trough":
			var a := float(g["a"]) + 0.3
			var L2 := float(g["length"]) * 0.5
			return AABB(Vector3(-maxf(a, L2), 0, -maxf(a, L2)), Vector3(maxf(a, L2) * 2.0, pw.y + a + float(g["f"]), maxf(a, L2) * 2.0))
	var sw := CspLabStructure.swing_radius(g, st.get("pivot_local", Vector3.ZERO) as Vector3)
	return AABB(Vector3(-sw, 0, -sw), Vector3(sw * 2.0, pw.y + sw, sw * 2.0))


# ---------------------------------------------------------------------------
# Optics
# ---------------------------------------------------------------------------

func _add_optic(g: Dictionary) -> void:
	var t := str(g["type"])
	match t:
		"parabolic_dish":
			var res := _paraboloid(float(g["a"]), float(g["f"]))
			_add_mesh(_content, "Mirror", res[0] as ArrayMesh)
			_add_mesh(_content, "Backing", res[1] as ArrayMesh)
		"parabolic_trough" when bool(g.get("cpc", false)):
			var res3 := _extruded_profile(g["cpc_prof"] as Dictionary, float(g["length"]))
			_add_mesh(_content, "Mirror", res3[0] as ArrayMesh)
			_add_mesh(_content, "Backing", res3[1] as ArrayMesh)
		"parabolic_trough":
			var res2 := _parabolic_strip(float(g["a"]), float(g["f"]), float(g["length"]))
			_add_mesh(_content, "Mirror", res2[0] as ArrayMesh)
			_add_mesh(_content, "Backing", res2[1] as ArrayMesh)
		"lens":
			_add_mesh(_content, "Lens", _lens_mesh(g))
		"ball_lens":
			var mi := MeshInstance3D.new()
			mi.name = "Lens"
			var sm := SphereMesh.new()
			sm.radius = float(g["R"])
			sm.height = float(g["R"]) * 2.0
			sm.radial_segments = 48
			sm.rings = 24
			mi.mesh = sm
			mi.position = Vector3(0, float(g["yc"]), 0)
			mi.material_override = _mat("water" if str(g["material"]) == "water" else "glass")
			_content.add_child(mi)
		"water_lens":
			_add_mesh(_content, "WaterLens", _water_mesh(g))
		"fresnel_lens":
			_add_mesh(_content, "FresnelLens", _fresnel_mesh(g))
			var rings := MeshInstance3D.new()
			rings.name = "Grooves"
			rings.mesh = _groove_lines(g)
			rings.material_override = _mat("groove")
			rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_content.add_child(rings)


func _add_mesh(parent: Node3D, n: String, m: Mesh, receiver: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = m
	if n == "Mirror" and _mirror_mat != null:
		for i in m.get_surface_count():
			if m.surface_get_material(i) == _mat("mirror"):
				mi.set_surface_override_material(i, _mirror_mat)
	parent.add_child(mi)
	if receiver:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


static func _paraboloid(a: float, f: float) -> Array:
	var front := _st("mirror")
	var back := _st("backing")
	var nr := 14
	var ns := 48
	for i in nr:
		for j in ns:
			var r0 := a * float(i) / float(nr)
			var r1 := a * float(i + 1) / float(nr)
			var p0 := _pb(r0, TAU * j / ns, f)
			var p1 := _pb(r1, TAU * j / ns, f)
			var p2 := _pb(r1, TAU * (j + 1) / ns, f)
			var p3 := _pb(r0, TAU * (j + 1) / ns, f)
			var n0 := _pbn(p0, f)
			var n1 := _pbn(p1, f)
			var n2 := _pbn(p2, f)
			var n3 := _pbn(p3, f)
			_quad(front, p0, p1, p2, p3, n0, n1, n2, n3)
			var o := 0.015
			_quad(back, p0 - n0 * o, p1 - n1 * o, p2 - n2 * o, p3 - n3 * o, -n0, -n1, -n2, -n3)
	return [front.commit(), back.commit()]


static func _pb(r: float, ang: float, f: float) -> Vector3:
	return Vector3(cos(ang) * r, r * r / (4.0 * f), sin(ang) * r)


static func _pbn(p: Vector3, f: float) -> Vector3:
	return Vector3(-p.x, 2.0 * f, -p.z).normalized()


static func _parabolic_strip(a: float, f: float, L: float) -> Array:
	var front := _st("mirror")
	var back := _st("backing")
	var nx := 28
	var nz := maxi(int(L / 2.0), 1)
	for i in nx:
		var x0 := -a + 2.0 * a * i / nx
		var x1 := -a + 2.0 * a * (i + 1) / nx
		for k in nz:
			var z0 := -L * 0.5 + L * k / nz
			var z1 := -L * 0.5 + L * (k + 1) / nz
			var p0 := Vector3(x0, x0 * x0 / (4.0 * f), z0)
			var p1 := Vector3(x1, x1 * x1 / (4.0 * f), z0)
			var p2 := Vector3(x1, x1 * x1 / (4.0 * f), z1)
			var p3 := Vector3(x0, x0 * x0 / (4.0 * f), z1)
			var n0 := Vector3(-x0, 2.0 * f, 0).normalized()
			var n1 := Vector3(-x1, 2.0 * f, 0).normalized()
			_quad(front, p0, p1, p2, p3, n0, n1, n1, n0)
			var o := 0.012
			_quad(back, p0 - n0 * o, p1 - n1 * o, p2 - n1 * o, p3 - n0 * o, -n0, -n1, -n1, -n0)
	return [front.commit(), back.commit()]


## A compound parabolic wall (both halves) extruded along Z, its mirror on
## the inner side (the profile's normals) and a backing behind it.
static func _extruded_profile(p: Dictionary, L: float) -> Array:
	var front := _st("mirror")
	var back := _st("backing")
	var nz := maxi(int(L / 2.0), 1)
	for side in [["right", "normals_r"], ["left", "normals_l"]]:
		var pts: PackedVector2Array = p[str(side[0])]
		var ns: PackedVector2Array = p[str(side[1])]
		for i in range(1, pts.size()):
			var a2 := pts[i - 1]
			var b2 := pts[i]
			var na := Vector3(ns[i - 1].x, ns[i - 1].y, 0.0)
			var nb := Vector3(ns[i].x, ns[i].y, 0.0)
			for k in nz:
				var z0 := -L * 0.5 + L * k / nz
				var z1 := -L * 0.5 + L * (k + 1) / nz
				var p0 := Vector3(a2.x, a2.y, z0)
				var p1 := Vector3(b2.x, b2.y, z0)
				var p2 := Vector3(b2.x, b2.y, z1)
				var p3 := Vector3(a2.x, a2.y, z1)
				_quad(front, p0, p1, p2, p3, na, nb, nb, na)
				var o := 0.008
				_quad(back, p0 - na * o, p1 - nb * o, p2 - nb * o, p3 - na * o, -na, -nb, -nb, -na)
	return [front.commit(), back.commit()]


func _lens_mesh(g: Dictionary) -> ArrayMesh:
	var stg := _st("water" if str(g["material"]) == "water" else "glass")
	var a := float(g["a"])
	var R := float(g["R"])
	var yc := float(g["yc"])
	var yf := float(g["y_flat"])
	var te := float(g["te"])
	var c := Vector3(0, yc, 0)
	var nr := 12
	var ns := 48
	for i in nr:
		for j in ns:
			var ps: Array = []
			for q in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var r := a * float(q[0]) / nr
				var ang := TAU * float(q[1]) / ns
				ps.append(Vector3(cos(ang) * r, yc + sqrt(maxf(R * R - r * r, 0.0)), sin(ang) * r))
			_quad(stg, ps[0], ps[1], ps[2], ps[3], (ps[0] - c).normalized(), (ps[1] - c).normalized(),
				(ps[2] - c).normalized(), (ps[3] - c).normalized())
	_disc(stg, Vector3(0, yf, 0), a, Vector3.DOWN, ns)
	_band(stg, a, yf, yf + te, ns)
	return stg.commit()


func _water_mesh(g: Dictionary) -> ArrayMesh:
	var stw := _st("water")
	var a := float(g["a"])
	var R := float(g["R"])
	var yc := float(g["yc"])
	var yt := float(g["y_top"])
	var rim := float(g["y_bot"]) + float(g["sag"])
	var c := Vector3(0, yc, 0)
	var nr := 12
	var ns := 48
	for i in nr:
		for j in ns:
			var ps: Array = []
			for q in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var r := a * float(q[0]) / nr
				var ang := TAU * float(q[1]) / ns
				ps.append(Vector3(cos(ang) * r, yc - sqrt(maxf(R * R - r * r, 0.0)), sin(ang) * r))
			_quad(stw, ps[0], ps[1], ps[2], ps[3], (ps[0] - c).normalized(), (ps[1] - c).normalized(),
				(ps[2] - c).normalized(), (ps[3] - c).normalized())
	_disc(stw, Vector3(0, yt, 0), a, Vector3.UP, ns)
	_band(stw, a, rim, yt, ns)
	return stw.commit()


func _fresnel_mesh(g: Dictionary) -> ArrayMesh:
	var stf := _st("glass")
	var a := float(g["a"])
	var yt := float(g["y_top"])
	var yg := float(g["y_groove"])
	if bool(g["square"]):
		var basis := Basis.IDENTITY
		_box(stf, Vector3(0, (yt + yg) * 0.5, 0), basis, Vector3(a, (yt - yg) * 0.5, a))
	else:
		_disc(stf, Vector3(0, yt, 0), a, Vector3.UP, 64)
		_disc(stf, Vector3(0, yg, 0), a, Vector3.DOWN, 64)
		_band(stf, a, yg, yt, 64)
	return stf.commit()


func _groove_lines(g: Dictionary) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	var a := float(g["a"])
	var y := float(g["y_groove"]) - 0.001
	var square := bool(g["square"])
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var rings := 14
	var maxr := a * (1.414 if square else 1.0)
	for k in range(1, rings + 1):
		var r := maxr * float(k) / float(rings)
		var segs := 72
		for j in segs:
			var a0 := TAU * j / segs
			var a1 := TAU * (j + 1) / segs
			var p0 := Vector3(cos(a0) * r, y, sin(a0) * r)
			var p1 := Vector3(cos(a1) * r, y, sin(a1) * r)
			if square and (absf(p0.x) > a or absf(p0.z) > a or absf(p1.x) > a or absf(p1.z) > a):
				continue
			im.surface_add_vertex(p0)
			im.surface_add_vertex(p1)
	im.surface_end()
	return im


func _receiver_mesh(g: Dictionary) -> ArrayMesh:
	var t := str(g["type"])
	var kind := str(g["rec_kind"])
	var sr := _st("receiver")
	var sh := _st("steel")
	var mat_r: StandardMaterial3D = _mat("receiver").duplicate() as StandardMaterial3D
	_receiver_mats.append(mat_r)
	var yr := float(g["rec_y"])
	var size := float(g["size"])
	var sh_used := true
	match t:
		"tower":
			var aim: Vector3 = g["aim"]
			var pw := float(g["panel_w"])
			var ph := float(g["panel_h"])
			if kind == "tube":
				_tube(sr, aim - Vector3(0, ph * 0.5, 0), aim + Vector3(0, ph * 0.5, 0), pw * 0.5, 32, true)
				sh_used = false
			else:
				var pn: Vector3 = g["panel_n"]
				var b := Basis(g["panel_u"] as Vector3, g["panel_v"] as Vector3, pn)
				_box(sr, aim + pn * 0.02, b, Vector3(pw * 0.5, ph * 0.5, 0.02))
				_box(sh, aim - pn * 0.25, b, Vector3(pw * 0.55, ph * 0.55, 0.22))
		"parabolic_trough" when bool(g.get("cpc", false)) and kind != "tube":
			# A flat CPC absorber lies at the bottom facing up, insulated below.
			var L3 := float(g["length"])
			_box(sr, Vector3(0, -0.005, 0), Basis.IDENTITY, Vector3(size * 0.5, 0.005, L3 * 0.5))
			_box(sh, Vector3(0, -0.045, 0), Basis.IDENTITY, Vector3(size * 0.55, 0.035, L3 * 0.5))
		"parabolic_trough", "linear_fresnel":
			var L := float(g["length"])
			if kind == "tube":
				_tube(sr, Vector3(0, yr, -L * 0.5), Vector3(0, yr, L * 0.5), size * 0.5, 16, true)
				sh_used = false
			else:
				_box(sr, Vector3(0, yr + 0.01, 0), Basis.IDENTITY, Vector3(size * 0.5, 0.01, L * 0.5))
				_box(sh, Vector3(0, yr + 0.1, 0), Basis.IDENTITY, Vector3(size * 0.75, 0.08, L * 0.5))
		"parabolic_dish":
			var rr := size * 0.5
			if kind == "cavity":
				_box(sh, Vector3(0, yr + rr * 0.9, 0), Basis.IDENTITY, Vector3(rr * 1.6, rr * 0.9, rr * 1.6))
				_disc(sr, Vector3(0, yr - 0.002, 0), rr, Vector3.DOWN, 32)
			else:
				_tube(sh, Vector3(0, yr, 0), Vector3(0, yr + maxf(rr * 0.4, 0.02), 0), float(g["house_r"]), 32, true)
				_disc(sr, Vector3(0, yr - 0.002, 0), rr, Vector3.DOWN, 32)
		_:
			var rr2 := size * 0.5
			if kind == "cavity":
				_box(sh, Vector3(0, yr - rr2 * 0.9, 0), Basis.IDENTITY, Vector3(rr2 * 1.6, rr2 * 0.9, rr2 * 1.6))
			else:
				_tube(sh, Vector3(0, yr - maxf(rr2 * 0.4, 0.02), 0), Vector3(0, yr, 0), rr2 * 1.15, 32, true)
			_disc(sr, Vector3(0, yr + 0.002, 0), rr2, Vector3.UP, 32)
	var m := sr.commit()
	m.surface_set_material(0, mat_r)
	if sh_used:
		var tmp := sh.commit()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, tmp.surface_get_arrays(0))
		m.surface_set_material(m.get_surface_count() - 1, _mat("steel"))
	if bool(g.get("envelope", false)) and kind == "tube":
		var se := _st("glass")
		var L2 := float(g["length"])
		_tube(se, Vector3(0, yr, -L2 * 0.5), Vector3(0, yr, L2 * 0.5), float(g.get("env_r", size)), 20, false)
		var em := se.commit()
		var arr2 := em.surface_get_arrays(0)
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr2)
		m.surface_set_material(m.get_surface_count() - 1, _mat("glass"))
	return m


## How many mirrors a field has (heliostats, or linear Fresnel rows).
static func _field_count(g: Dictionary) -> int:
	if str(g["type"]) == "tower":
		return (g["centres"] as PackedVector3Array).size()
	return (g["xs"] as PackedFloat64Array).size()


## One heliostat (or row) at the origin facing +Z: its mirror face
## (surface 0) and backing + back frame (surface 1). Every mirror of the
## field is an instance of it.
func _field_unit_mesh(g: Dictionary) -> ArrayMesh:
	var sm := _st("mirror")
	var sb := _st("backing")
	if str(g["type"]) == "tower":
		var hw := float(g["hw"]) * 0.5
		var hh := float(g["hh"]) * 0.5
		_plate(sm, sb, Vector3.ZERO, Basis.IDENTITY, hw, hh, 0.03)
		_back_frame(sb, Vector3.ZERO, Basis.IDENTITY, hw, hh, 0.03)
	else:
		var hw2 := float(g["w"]) * 0.5
		var hl := float(g["length"]) * 0.5
		_plate(sm, sb, Vector3.ZERO, Basis.IDENTITY, hw2, hl, 0.012)
		_row_back(sb, Vector3.ZERO, Basis.IDENTITY, hw2, hl, 0.012)
	var m := sm.commit()
	m.surface_set_material(0, _mirror_mat if _mirror_mat != null else _mat("mirror"))
	var mb := sb.commit()
	if mb.get_surface_count() > 0:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mb.surface_get_arrays(0))
		m.surface_set_material(1, _mat("backing"))
	return m


## Each mirror of the field faced to reflect the sun (local `sl`) onto the
## receiver: only the instance transforms move.
func _aim_field(g: Dictionary, sl: Vector3) -> void:
	if _field_mm == null or _field_mm.multimesh == null:
		return
	var mm := _field_mm.multimesh
	var xfs := _field_transforms(g, sl)
	for i in mini(xfs.size(), mm.instance_count):
		mm.set_instance_transform(i, xfs[i] as Transform3D)


## Where each mirror of a field stands and faces for the local sun `sl`.
## The unit mirror is symmetric across its width, so a left-handed frame is
## turned right-handed by flipping that axis (a MultiMesh instance with a
## negative determinant would be drawn inside out).
static func _field_transforms(g: Dictionary, sl: Vector3) -> Array:
	var out: Array = []
	var pose := CspLabOptics.field_pose(g, sl)
	var ns: PackedVector3Array = pose["n"]
	var us: PackedVector3Array = pose["u"]
	if str(g["type"]) == "tower":
		var cs: PackedVector3Array = g["centres"]
		var vs: PackedVector3Array = pose["v"]
		for i in cs.size():
			var bt := Basis(us[i], vs[i], ns[i])
			if bt.determinant() < 0.0:
				bt.x = -bt.x
			out.append(Transform3D(bt, cs[i]))
	else:
		var xs: PackedFloat64Array = g["xs"]
		for i in xs.size():
			var br := Basis(us[i], Vector3.BACK, ns[i])
			if br.determinant() < 0.0:
				br.x = -br.x
			out.append(Transform3D(br, Vector3(xs[i], 0, 0)))
	return out


## The field's mirror transforms now (for picking and tests; a headless
## MultiMesh keeps none).
func field_mirror_transforms() -> Array:
	if _field_mm == null:
		return []
	var sl: Vector3 = last_pose.get("sun_local", Vector3.UP)
	if sl.y <= 0.02:
		sl = CspLabDesign.design_sun_local(spec)
	return _field_transforms(design["geo"] as Dictionary, sl)


## A flat mirror plate: face along the basis Z (the normal), half sizes
## along X and Y, `th` thick behind the face.
static func _plate(sm: SurfaceTool, sb: SurfaceTool, c: Vector3, b: Basis, hu: float, hv: float, th: float) -> void:
	var u := b.x
	var v := b.y
	var n := b.z
	var p0 := c - u * hu - v * hv
	var p1 := c + u * hu - v * hv
	var p2 := c + u * hu + v * hv
	var p3 := c - u * hu + v * hv
	_quad(sm, p0, p1, p2, p3, n, n, n, n)
	_box(sb, c - n * th * 0.5 - n * 0.002, b, Vector3(hu, hv, th * 0.5))


## A heliostat's back frame: a torque tube across the middle (the
## elevation axis on the drive) and purlins that carry the facets.
static func _back_frame(sb: SurfaceTool, c: Vector3, b: Basis, hu: float, hv: float, th: float) -> void:
	var u := b.x
	var v := b.y
	var n := b.z
	var tt := clampf(hu * 0.05, 0.025, 0.12)
	var pr := tt * 0.55
	var back := c - n * (th + tt)
	_box(sb, back, b, Vector3(hu * 0.9, tt, tt))
	for k in 4:
		var x := lerpf(-hu * 0.75, hu * 0.75, float(k) / 3.0)
		_box(sb, c - n * (th + pr) + u * x, b, Vector3(pr, hv * 0.92, pr))
	_box(sb, back - n * tt * 1.5, b, Vector3(tt * 1.2, tt * 1.2, tt * 0.8))


## A linear Fresnel row's back: a shaft along the row and cross-stiffeners.
static func _row_back(sb: SurfaceTool, c: Vector3, b: Basis, hu: float, hl: float, th: float) -> void:
	var n := b.z
	var tt := clampf(hu * 0.06, 0.012, 0.05)
	_box(sb, c - n * (th + tt), b, Vector3(tt, hl, tt))
	var k := 0
	var steps := maxi(int(hl * 2.0 / 1.0), 1)
	while k <= steps:
		var z := lerpf(-hl * 0.97, hl * 0.97, float(k) / float(steps))
		_box(sb, c - n * (th + tt * 0.5) + b.y * z, b, Vector3(hu * 0.9, tt * 0.4, tt * 0.5))
		k += 1


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

func _add_members(st: Dictionary) -> void:
	# One surface per frame and material: steel tubes, drives and boxes,
	# concrete footings, cast-iron counterweights.
	var tools := {}
	var counts := {}
	member_segments.clear()
	for mv in (st["members"] as Array):
		var m: Dictionary = mv
		var fr := str(m["frame"])
		if fr == "cart" and _cart == null:
			fr = "optic"
		if fr != "base" and fr != "stage" and fr != "optic" and fr != "cart":
			fr = "base"
		if is_field() and fr != "base":
			fr = "base"
		var box := bool(m.get("box", false))
		var mk := str(m.get("mat", "drive" if box else "steel"))
		var key := fr + "|" + mk
		if not tools.has(key):
			tools[key] = _st(mk)
			counts[key] = 0
		var a: Vector3 = m["a"]
		var b: Vector3 = m["b"]
		if box:
			var ax := (b - a)
			var seg_len := maxf(ax.length(), 0.01)
			var y := ax / seg_len if ax.length() > 1e-6 else Vector3.UP
			var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
			var z := x.cross(y).normalized()
			_box(tools[key] as SurfaceTool, (a + b) * 0.5, Basis(x, y, z), Vector3(float(m["w"]) * 0.5, seg_len * 0.5, float(m["h"]) * 0.5))
		else:
			_tube(tools[key] as SurfaceTool, a, b, float(m["d"]) * 0.5, 10 if float(m["d"]) > 0.08 else 8, true)
		counts[key] = int(counts[key]) + 1
		member_segments.append({"frame": fr, "a": a, "b": b,
			"r": maxf(float(m.get("d", maxf(float(m.get("w", 0.05)), float(m.get("h", 0.05))))) * 0.5, 0.01), "m": m})
	var parents := _frame_parents()
	var by_frame := {}
	for key2 in tools:
		if int(counts[key2]) <= 0:
			continue
		var fr2 := str(key2).get_slice("|", 0)
		var mesh: ArrayMesh = by_frame.get(fr2, ArrayMesh.new()) as ArrayMesh
		var part := (tools[key2] as SurfaceTool).commit()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, part.surface_get_arrays(0))
		mesh.surface_set_material(mesh.get_surface_count() - 1, _mat(str(key2).get_slice("|", 1)))
		by_frame[fr2] = mesh
	for fr3 in by_frame:
		_add_mesh(parents[fr3] as Node3D, "Members_" + str(fr3), by_frame[fr3] as ArrayMesh)


## The member under a world-space ray (the structure view's hover), or {}.
## Each member is tested as a capsule round its axis.
func pick_member(origin: Vector3, dir: Vector3) -> Dictionary:
	var parents := _frame_parents()
	var best := {}
	var best_t := INF
	for sv in member_segments:
		var sg: Dictionary = sv
		var node := parents[str(sg["frame"])] as Node3D
		if node == null or not node.is_inside_tree():
			continue
		var xf := node.global_transform
		var pa: Vector3 = xf * (sg["a"] as Vector3)
		var pb: Vector3 = xf * (sg["b"] as Vector3)
		var r := float(sg["r"]) * xf.basis.get_scale().x
		var hit := _ray_segment(origin, dir, pa, pb)
		if hit.x <= r + 0.02 and hit.y < best_t:
			best_t = hit.y
			best = sg["m"] as Dictionary
	return best


## Distance from a ray to a segment and the ray parameter there: (dist, t).
static func _ray_segment(o: Vector3, d: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var u := d.normalized()
	var v := b - a
	var w := o - a
	var aa := u.dot(u)
	var bb := u.dot(v)
	var cc := v.dot(v)
	var dd := u.dot(w)
	var ee := v.dot(w)
	var den := aa * cc - bb * bb
	var sc := 0.0
	var tc := 0.0
	if den < 1e-9:
		tc = clampf(ee / maxf(cc, 1e-9), 0.0, 1.0)
		sc = maxf((bb * tc - dd) / aa, 0.0)
	else:
		tc = clampf((aa * ee - bb * dd) / den, 0.0, 1.0)
		sc = maxf((bb * tc - dd) / aa, 0.0)
	var p := o + u * sc
	var q := a + v * tc
	return Vector2(p.distance_to(q), sc)


# ---------------------------------------------------------------------------
# Axes overlay
# ---------------------------------------------------------------------------

func _clear_axes() -> void:
	for c in _axes.get_children():
		_axes.remove_child(c)
		c.free()


func _build_axes(p: Dictionary) -> void:
	_clear_axes()
	var st: Dictionary = design["structure"]
	var pw: Vector3 = st.get("pivot_world", Vector3.ZERO)
	var g: Dictionary = design["geo"]
	var reach := clampf(float(g.get("a", 1.0)) * 1.6 + 0.5, 1.0, 30.0)
	if is_field():
		reach = clampf(float(g.get("H", 3.0)) * 0.3, 1.5, 12.0)
	var i := 0
	for av in (p.get("axes", []) as Array):
		var ad: Dictionary = av
		var dir: Vector3 = (ad["dir"] as Vector3).normalized()
		var col: Color = ad["color"]
		var origin := pw
		if is_field():
			origin = Vector3(0, 0.1, 0) if str(spec["type"]) == "tower" else pw + Vector3(0, 0.3, 0)
			if str(spec["type"]) == "tower" and i == 1:
				var cs: PackedVector3Array = g["centres"]
				if cs.size() > 0:
					origin = cs[0]
		var line := MeshInstance3D.new()
		var stt := _st("axis")
		_tube(stt, origin - dir * reach, origin + dir * reach, maxf(reach * 0.005, 0.008), 8, true)
		var am := stt.commit()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		mat.no_depth_test = true
		mat.render_priority = 2
		am.surface_set_material(0, mat)
		line.mesh = am
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_axes.add_child(line)
		var lbl := Label3D.new()
		lbl.text = str(ad["label"])
		lbl.modulate = col
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.fixed_size = true
		lbl.pixel_size = 0.0012
		lbl.font_size = 28
		lbl.outline_size = 8
		lbl.position = origin + dir * (reach + 0.15)
		# Two axes through one point would print their names on top of each other.
		lbl.offset = Vector2(0, -34.0 * i)
		_axes.add_child(lbl)
		i += 1


# ---------------------------------------------------------------------------
# Mesh helpers
# ---------------------------------------------------------------------------

static func _st(kind: String) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(kind))
	return st


## One triangle, wound clockwise seen from its normal side (Godot's front).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	var face := (b - a).cross(c - a)
	if face.length_squared() < 1e-14:
		return
	if face.dot(na + nb + nc) > 0.0:
		st.set_normal(na)
		st.add_vertex(a)
		st.set_normal(nc)
		st.add_vertex(c)
		st.set_normal(nb)
		st.add_vertex(b)
	else:
		st.set_normal(na)
		st.add_vertex(a)
		st.set_normal(nb)
		st.add_vertex(b)
		st.set_normal(nc)
		st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	_tri(st, a, b, c, na, nb, nc)
	_tri(st, a, c, d, na, nc, nd)


static func _disc(st: SurfaceTool, c: Vector3, r: float, n: Vector3, segs: int) -> void:
	var u := n.cross(Vector3.FORWARD if absf(n.z) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		_tri(st, c, c + (u * cos(a0) + v * sin(a0)) * r, c + (u * cos(a1) + v * sin(a1)) * r, n, n, n)


static func _band(st: SurfaceTool, r: float, y0: float, y1: float, segs: int) -> void:
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		var n0 := Vector3(cos(a0), 0, sin(a0))
		var n1 := Vector3(cos(a1), 0, sin(a1))
		_quad(st, n0 * r + Vector3(0, y0, 0), n1 * r + Vector3(0, y0, 0), n1 * r + Vector3(0, y1, 0), n0 * r + Vector3(0, y1, 0),
			n0, n1, n1, n0)


static func _tube(st: SurfaceTool, a: Vector3, b: Vector3, r: float, sides: int, caps: bool) -> void:
	var ax := b - a
	var seg_len := ax.length()
	if seg_len < 1e-5:
		return
	var w := ax / seg_len
	var u := w.cross(Vector3.UP if absf(w.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := w.cross(u)
	for j in sides:
		var a0 := TAU * j / sides
		var a1 := TAU * (j + 1) / sides
		var n0 := u * cos(a0) + v * sin(a0)
		var n1 := u * cos(a1) + v * sin(a1)
		_quad(st, a + n0 * r, a + n1 * r, b + n1 * r, b + n0 * r, n0, n1, n1, n0)
		if caps:
			_tri(st, a, a + n1 * r, a + n0 * r, -w, -w, -w)
			_tri(st, b, b + n0 * r, b + n1 * r, w, w, w)


## A box: centre, orientation, half extents along the basis columns.
static func _box(st: SurfaceTool, c: Vector3, b: Basis, h: Vector3) -> void:
	var ax := [b.x.normalized(), b.y.normalized(), b.z.normalized()]
	var hs := [h.x, h.y, h.z]
	for i in 3:
		var n: Vector3 = ax[i]
		var u: Vector3 = ax[(i + 1) % 3]
		var v: Vector3 = ax[(i + 2) % 3]
		var hn := float(hs[i])
		var hu := float(hs[(i + 1) % 3])
		var hv := float(hs[(i + 2) % 3])
		for sgn in [1.0, -1.0]:
			var nn: Vector3 = n * float(sgn)
			var fc: Vector3 = c + nn * hn
			_quad(st, fc - u * hu - v * hv, fc + u * hu - v * hv, fc + u * hu + v * hv, fc - u * hu + v * hv, nn, nn, nn, nn)


static func _mat(kind: String) -> Material:
	if _mats.has(kind):
		return _mats[kind] as Material
	var m := StandardMaterial3D.new()
	match kind:
		"mirror":
			# A shader material (csplab_mirror.gdshader); every builder
			# takes its own copy for its sun.
			var sm := ShaderMaterial.new()
			sm.shader = _MIRROR_SHADER
			_mats[kind] = sm
			return sm
		"backing":
			m.albedo_color = Color(0.5, 0.52, 0.55)
			m.metallic = 0.3
			m.roughness = 0.6
		"glass":
			m.albedo_color = Color(0.72, 0.9, 0.96, 0.3)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.04
			m.metallic_specular = 0.9
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"water":
			m.albedo_color = Color(0.3, 0.58, 0.85, 0.45)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.03
			m.metallic_specular = 0.8
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		"steel":
			m.albedo_color = Color(0.42, 0.44, 0.47)
			m.metallic = 0.6
			m.roughness = 0.45
		"drive":
			m.albedo_color = Color(0.2, 0.26, 0.34)
			m.metallic = 0.4
			m.roughness = 0.5
		"concrete":
			m.albedo_color = Color(0.62, 0.61, 0.58)
			m.roughness = 0.95
		"counterweight":
			m.albedo_color = Color(0.17, 0.17, 0.18)
			m.metallic = 0.5
			m.roughness = 0.7
		"receiver":
			m.albedo_color = Color(0.07, 0.07, 0.07)
			m.roughness = 0.5
			m.emission_enabled = true
			m.emission = Color(1.0, 0.45, 0.12)
			m.emission_energy_multiplier = 0.0
		"groove":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Color(0.85, 0.95, 1.0, 0.35)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		"rays":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.vertex_color_use_as_albedo = true
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		"axis":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"sun":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Color(1.0, 0.88, 0.35)
		"highlight":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Color(0.13, 0.83, 0.93, 0.55)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.no_depth_test = true
			m.render_priority = 3
	_mats[kind] = m
	return m

class_name PoiRuntime
extends Node3D

## The 3D side of the points-of-interest layer: one pin per point record (a
## pole with a coloured head, a ground disc and a name tag), a draped ribbon
## per line / polygon record with a shorter labelled pole at its centroid.
##
## Built from a PoiLayer + the site centre + a ground callable, rebuilt
## whole on `sync` (a site has a dozen pins, not a thousand). Primitive
## meshes only (no winding traps), unshaded so a pin reads the same by night
## — and the name tag is `no_depth_test`: the whole point of a pin is finding
## it, through the trees and from the far side of the hill.

const NODE_NAME := "PointsOfInterest"
const POLE_H := 2.6
const HEAD_R := 0.22
const DISC_R := 0.55
const LINE_POLE_H := 1.5
const LINE_LIFT_M := 0.15
const LINE_W := 0.4
const SAMPLE_M := 2.0
## Screen-constant: readable from the drone AND at arm's length. (0.0011 made
## a dozen pins' names pile up over each other in the aerial shot.)
const LABEL_PIXEL := 0.0009
const LABEL_RANGE_M := 2500.0
## The name tags are FIRST-PERSON furniture (screen-size, seen through
## terrain): on their own render layer, which the systems graph's lens
## preview camera excludes — the graph draws its own pin names, and the tags
## rendered as giant see-through text across Site Plan / Elevation / Globe.
const LABEL_RENDER_LAYER := 1 << 18

var _markers: Dictionary = {}   # id -> Node3D
var _shown := true


## Rebuild every marker. `ground_fn(x, z) -> float` is the world height at
## that site-relative xz (the loader's edit-aware surface).
func sync(layer: PoiLayer, center_lat: float, center_lon: float, ground_fn: Callable) -> void:
	for ch in get_children():
		remove_child(ch)
		ch.queue_free()
	_markers.clear()
	if layer == null:
		return
	for rec in layer.records:
		var id := str(rec.get("id", ""))
		if id.is_empty():
			continue
		var node := _build(rec, center_lat, center_lon, ground_fn)
		if node == null:
			continue
		node.name = "Poi_" + id
		node.visible = _shown
		add_child(node)
		_markers[id] = node


func marker_count() -> int:
	return _markers.size()


func marker_ids() -> Array:
	return _markers.keys()


## World position of a marker's anchor (the pole's foot), or Vector3.INF.
func marker_position(id: String) -> Vector3:
	var n: Node3D = _markers.get(id, null)
	if n == null or not is_instance_valid(n):
		return Vector3.INF
	return n.position


func set_shown(on: bool) -> void:
	_shown = on
	for n in _markers.values():
		if is_instance_valid(n):
			(n as Node3D).visible = on


func is_shown() -> bool:
	return _shown


func _build(rec: Dictionary, center_lat: float, center_lon: float, ground_fn: Callable) -> Node3D:
	var kind := str(rec.get("kind", KmlPoiParser.KIND_POINT))
	var col := PoiLayer.color_of(rec)
	var anchor := PoiLayer.world_xz(rec, center_lat, center_lon)
	if not is_finite(anchor.x) or not is_finite(anchor.y):
		return null
	var gy := _ground(ground_fn, anchor.x, anchor.y)
	var root := Node3D.new()
	root.position = Vector3(anchor.x, gy, anchor.y)
	if kind == KmlPoiParser.KIND_POINT:
		_add_pole(root, POLE_H, col, true)
	else:
		var pts := PoiLayer.points_world_xz(rec, center_lat, center_lon)
		if pts.size() >= 2:
			var ribbon := _build_ribbon(pts, kind == KmlPoiParser.KIND_POLYGON, ground_fn, col)
			if ribbon != null:
				# Ribbon vertices are world-space; undo the root's offset.
				ribbon.position = -root.position
				root.add_child(ribbon)
		_add_pole(root, LINE_POLE_H, col, false)
	_add_label(root, str(rec.get("name", "")), str(rec.get("desc", "")),
		(POLE_H if kind == KmlPoiParser.KIND_POINT else LINE_POLE_H) + 0.45)
	return root


func _ground(ground_fn: Callable, x: float, z: float) -> float:
	if not ground_fn.is_valid():
		return 0.0
	var y: Variant = ground_fn.call(x, z)
	return float(y) if (y is float or y is int) and is_finite(float(y)) else 0.0


func _add_pole(root: Node3D, h: float, col: Color, with_disc: bool) -> void:
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.03
	pm.bottom_radius = 0.03
	pm.height = h
	pm.radial_segments = 8
	pole.mesh = pm
	pole.position = Vector3(0.0, h * 0.5, 0.0)
	pole.material_override = _mat(Color(0.92, 0.94, 0.96), 0.0)
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pole)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = HEAD_R
	sm.height = HEAD_R * 2.0
	sm.radial_segments = 16
	sm.rings = 8
	head.mesh = sm
	head.position = Vector3(0.0, h, 0.0)
	head.material_override = _mat(col, 0.6)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)
	if with_disc:
		var disc := MeshInstance3D.new()
		var dm := CylinderMesh.new()
		dm.top_radius = DISC_R
		dm.bottom_radius = DISC_R
		dm.height = 0.04
		dm.radial_segments = 24
		disc.mesh = dm
		disc.position = Vector3(0.0, 0.03, 0.0)
		var m := _mat(col, 0.0)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(col.r, col.g, col.b, 0.45)
		disc.material_override = m
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(disc)


func _add_label(root: Node3D, text: String, desc: String, y: float) -> void:
	var lbl := Label3D.new()
	lbl.name = "Label"
	lbl.text = text
	lbl.font_size = 44
	lbl.fixed_size = true
	lbl.pixel_size = LABEL_PIXEL
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.modulate = Color(1, 1, 1, 0.97)
	lbl.outline_modulate = Color(0.02, 0.04, 0.09, 0.92)
	lbl.outline_size = 10
	lbl.position = Vector3(0.0, y, 0.0)
	lbl.visibility_range_end = LABEL_RANGE_M
	lbl.layers = LABEL_RENDER_LAYER
	root.add_child(lbl)
	if desc.is_empty():
		return
	var sub := Label3D.new()
	sub.name = "Desc"
	sub.text = desc.left(120)
	sub.font_size = 26
	sub.fixed_size = true
	sub.pixel_size = LABEL_PIXEL
	sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sub.no_depth_test = true
	sub.modulate = Color(0.85, 0.90, 0.96, 0.92)
	sub.outline_modulate = Color(0.02, 0.04, 0.09, 0.9)
	sub.outline_size = 8
	sub.position = Vector3(0.0, y - 0.32, 0.0)
	sub.layers = LABEL_RENDER_LAYER
	# Only readable close up; from the drone the name is enough.
	sub.visibility_range_end = 60.0
	root.add_child(sub)


## A flat ribbon LINE_W wide following the ground every SAMPLE_M, lifted
## LINE_LIFT_M so it does not z-fight the drape. World-space vertices.
func _build_ribbon(pts: PackedVector2Array, closed: bool, ground_fn: Callable, col: Color) -> MeshInstance3D:
	var path := PackedVector2Array(pts)
	if closed:
		path.append(pts[0])
	var samples := PackedVector3Array()
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var seg := a.distance_to(b)
		var n := maxi(1, int(ceil(seg / SAMPLE_M)))
		for k in n:
			var t := float(k) / float(n)
			var p := a.lerp(b, t)
			samples.append(Vector3(p.x, _ground(ground_fn, p.x, p.y) + LINE_LIFT_M, p.y))
	var last := path[path.size() - 1]
	samples.append(Vector3(last.x, _ground(ground_fn, last.x, last.y) + LINE_LIFT_M, last.y))
	if samples.size() < 2:
		return null
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in samples.size():
		var prev := samples[maxi(i - 1, 0)]
		var nxt := samples[mini(i + 1, samples.size() - 1)]
		var dir := Vector3(nxt.x - prev.x, 0.0, nxt.z - prev.z)
		if dir.length_squared() < 1e-8:
			dir = Vector3(1, 0, 0)
		var side := Vector3(-dir.z, 0.0, dir.x).normalized() * (LINE_W * 0.5)
		verts.append(samples[i] + side)
		verts.append(samples[i] - side)
	for i in range(samples.size() - 1):
		var a := i * 2
		idx.append(a)
		idx.append(a + 2)
		idx.append(a + 1)
		idx.append(a + 1)
		idx.append(a + 2)
		idx.append(a + 3)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Ribbon"
	mi.mesh = mesh
	var m := _mat(col, 0.25)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _mat(col: Color, emission: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emission
	return m

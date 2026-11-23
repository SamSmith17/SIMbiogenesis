class_name BasementBuilder
extends RefCounted

## A basement under a building's footprint (pure geometry + the earthworks it
## asks for). The house body stands at grade as before; below it, foundation
## walls (their outer face ON the footprint line, where the terrain's opening
## is cut), a slab, and a door in one wall that opens onto either an areaway
## (a narrow trench with steps up) or a walkout (the ground dug away on that
## side). The building spec carries it as `basement`:
##   {depth_m (0 = none), wall_t, entry "areaway" | "walkout" | "none",
##    edge (footprint edge index the door is in), door_at (0..1 along it)}
## Frame: the building's own (footprint centred on the origin, y = 0 = grade).

const KEY := "basement"
const DOOR_W := 1.0
const DOOR_H := 2.05
const SLAB_T := 0.15
const FOOTING_M := 0.3
## Just under the house body's foundation skirt (it reaches 0.35 m below
## grade, y = 0), or the house's own floor covers the ceiling from below.
const CEILING_Y := -0.38
const ENTRIES := ["areaway", "walkout", "none"]


static func defaults() -> Dictionary:
	return {"depth_m": 0.0, "wall_t": 0.25, "entry": "areaway", "edge": 0, "door_at": 0.5}


static func resolve(b_in: Variant) -> Dictionary:
	var b := defaults()
	if b_in is Dictionary:
		for k in (b_in as Dictionary).keys():
			b[k] = (b_in as Dictionary)[k]
	b["depth_m"] = clampf(float(b.get("depth_m", 0.0)), 0.0, 6.0)
	b["wall_t"] = clampf(float(b.get("wall_t", 0.25)), 0.15, 0.6)
	if not ENTRIES.has(str(b.get("entry", "areaway"))):
		b["entry"] = "areaway"
	b["edge"] = maxi(int(b.get("edge", 0)), 0)
	b["door_at"] = clampf(float(b.get("door_at", 0.5)), 0.1, 0.9)
	return b


static func has_basement(spec: Dictionary) -> bool:
	return spec.get(KEY, null) is Dictionary and float((spec[KEY] as Dictionary).get("depth_m", 0.0)) > 0.3


## The side (StructureEarthworks.SIDES) an edge of the footprint faces.
static func side_of_edge(poly: PackedVector2Array, edge: int) -> String:
	var n := poly.size()
	var e := clampi(edge, 0, n - 1)
	var out := StructureEarthworks.outward(poly, poly[e], poly[(e + 1) % n])
	if absf(out.x) > absf(out.y):
		return "+x" if out.x > 0.0 else "-x"
	return "+z" if out.y > 0.0 else "-z"


## The door's centre on the footprint (building frame).
static func door_point(poly: PackedVector2Array, b: Dictionary) -> Vector2:
	var n := poly.size()
	var e := clampi(int(b["edge"]), 0, n - 1)
	return poly[e].lerp(poly[(e + 1) % n], float(b["door_at"]))


## The earthworks simple form for a building with a basement: the opening
## over the footprint at the basement floor, and the entry side dug out.
static func earthworks_simple(poly: PackedVector2Array, b_in: Variant, height_m: float) -> Dictionary:
	var b := resolve(b_in)
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	var arr: Array = []
	for p in poly:
		arr.append([p.x, p.y])
	var depth := float(b["depth_m"])
	var sm := {"sink_m": 0.0, "rect": [r.position.x, r.position.y, r.end.x, r.end.y],
		"poly": arr, "hole": true, "floor_y": -depth, "roof_y": maxf(height_m, 2.5),
		"slab": false, "walls": false, "berm": {}, "berm_run": 1.5, "daylight": "",
		"cut_w": 1.3, "ramp_len": 0.0, "ramp_w": 1.1}
	var entry := str(b["entry"])
	if entry != "none":
		var side := side_of_edge(poly, int(b["edge"]))
		var dp := door_point(poly, b)
		sm["daylight"] = side
		sm["cut_w"] = 4.0 if entry == "walkout" else 1.3
		sm["ramp_len"] = depth * (3.0 if entry == "walkout" else 2.0)
		sm["ramp_w"] = 1.6 if entry == "walkout" else 1.1
		sm["ramp_at"] = dp.x if side.ends_with("z") else dp.y
	return sm


## The earthworks spec a building record asks for (empty without a basement).
static func earthworks_for_building(spec: Dictionary) -> Dictionary:
	if not has_basement(spec):
		return {}
	var poly := BuildingFeatures.footprint_of(spec)
	return StructureEarthworks.from_simple(earthworks_simple(poly, spec[KEY], float(spec.get("height_m", 4.0))))


## The basement as a node: walls, slab, door frame. Collides like any mesh
## under a placed prop (no skip meta).
static func build(poly: PackedVector2Array, b_in: Variant) -> Node3D:
	var b := resolve(b_in)
	var root := Node3D.new()
	root.name = "Basement"
	var depth := float(b["depth_m"])
	if depth <= 0.3 or poly.size() < 3:
		return root
	var wt := float(b["wall_t"])
	var yf := -depth
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	var door_e := clampi(int(b["edge"]), 0, n - 1) if str(b["entry"]) != "none" else -1
	for i in n:
		var a := poly[i]
		var c := poly[(i + 1) % n]
		var elen := a.distance_to(c)
		if elen < 0.05:
			continue
		var dir := (c - a) / elen
		var inward := -StructureEarthworks.outward(poly, a, c)
		var segs: Array = [[0.0, elen]]
		if i == door_e:
			var mid := float(b["door_at"]) * elen
			var d0 := clampf(mid - DOOR_W * 0.5, 0.0, elen)
			var d1 := clampf(mid + DOOR_W * 0.5, 0.0, elen)
			segs = [[0.0, d0], [d1, elen]]
			var head := minf(yf + DOOR_H, CEILING_Y)
			_wall(walls, a + dir * d0, a + dir * d1, inward, wt, head, 0.0)
		for sg in segs:
			var s0: float = sg[0]
			var s1: float = sg[1]
			if s1 - s0 > 0.02:
				_wall(walls, a + dir * s0, a + dir * s1, inward, wt, yf - FOOTING_M, 0.0)
	var wm := MeshInstance3D.new()
	wm.name = "FoundationWalls"
	wm.mesh = walls.commit()
	wm.material_override = _concrete(Color(0.62, 0.6, 0.56))
	root.add_child(wm)
	var slab := SurfaceTool.new()
	slab.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := Geometry2D.triangulate_polygon(poly)
	for k in range(0, idx.size(), 3):
		for j in [0, 1, 2]:
			var p := poly[idx[k + j]]
			slab.set_normal(Vector3.UP)
			slab.add_vertex(Vector3(p.x, yf, p.y))
	var sm := MeshInstance3D.new()
	sm.name = "Slab"
	sm.mesh = slab.commit()
	sm.material_override = _concrete(Color(0.55, 0.54, 0.52))
	root.add_child(sm)
	# The ceiling: the house's ground floor seen from below (the house mesh
	# draws its floor from above only).
	var ceil_st := SurfaceTool.new()
	ceil_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(0, idx.size(), 3):
		for j in [2, 1, 0]:
			var q := poly[idx[k + j]]
			ceil_st.set_normal(Vector3.DOWN)
			ceil_st.add_vertex(Vector3(q.x, CEILING_Y, q.y))
	var cm := MeshInstance3D.new()
	cm.name = "Ceiling"
	cm.mesh = ceil_st.commit()
	cm.material_override = _concrete(Color(0.74, 0.72, 0.68))
	cm.set_meta("skip_prop_collision", true)
	root.add_child(cm)
	return root


## One wall piece: outer face on a→c, `t` thick toward `inward`, from y0 to y1.
static func _wall(st: SurfaceTool, a: Vector2, c: Vector2, inward: Vector2, t: float, y0: float, y1: float) -> void:
	var a2 := a + inward * t
	var c2 := c + inward * t
	var p := [Vector3(a.x, y0, a.y), Vector3(c.x, y0, c.y), Vector3(c.x, y1, c.y), Vector3(a.x, y1, a.y),
		Vector3(a2.x, y0, a2.y), Vector3(c2.x, y0, c2.y), Vector3(c2.x, y1, c2.y), Vector3(a2.x, y1, a2.y)]
	var nin := Vector3(inward.x, 0.0, inward.y)
	_quad(st, p[0], p[1], p[2], p[3], -nin)
	_quad(st, p[5], p[4], p[7], p[6], nin)
	_quad(st, p[3], p[2], p[6], p[7], Vector3.UP)
	_quad(st, p[0], p[4], p[5], p[1], Vector3.DOWN)
	_quad(st, p[4], p[0], p[3], p[7], (Vector3(a.x, 0, a.y) - Vector3(c.x, 0, c.y)).normalized())
	_quad(st, p[1], p[5], p[6], p[2], (Vector3(c.x, 0, c.y) - Vector3(a.x, 0, a.y)).normalized())


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.add_vertex(v)


static func _concrete(c: Color) -> StandardMaterial3D:
	return ParametricMaterialLibrary.make("concrete", c, {"world_triplanar": true})

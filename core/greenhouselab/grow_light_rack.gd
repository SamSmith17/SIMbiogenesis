class_name GrowLightRack
extends RefCounted

## A rack of LED grow-light bars hung over one bed (record key
## `light_rack_spec`, model `grow_light_rack`). Its own prop, mounted on its
## greenhouse. Spec:
##   {shape: "rect"|"ring", length_m (X), width_m (Z) — rect;
##    outer_r, inner_r — ring (over a keyhole), hang_m: bars above the floor,
##    watts}
## Bars run along the bed every BAR_PITCH_M (rect) or radially every
## ~BAR_PITCH_M of the outer arc (ring), hung on wires to the hang height + 1 m.
## `set_lit(model, on)` turns the bars' glow on and off.

const MODEL_ID := "grow_light_rack"
const KEY := "light_rack_spec"
const BAR_PITCH_M := 0.3
const BAR_W := 0.045
const BAR_H := 0.03
const LIT_COLOR := Color(1.0, 0.55, 0.85)


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["shape"] = "ring" if str(s.get("shape", "rect")) == "ring" else "rect"
	s["length_m"] = clampf(float(s.get("length_m", 2.4)), 0.3, 60.0)
	s["width_m"] = clampf(float(s.get("width_m", 1.2)), 0.2, 6.0)
	s["outer_r"] = clampf(float(s.get("outer_r", 3.0)), 0.5, 30.0)
	s["inner_r"] = clampf(float(s.get("inner_r", 1.0)), 0.0, float(s["outer_r"]) - 0.3)
	s["hang_m"] = clampf(float(s.get("hang_m", 1.0)), 0.2, 4.0)
	s["watts"] = maxf(float(s.get("watts", 0.0)), 0.0)
	return s


## The bars as [a, b] segments at hang height (local).
static func bars(spec: Dictionary) -> Array:
	var s := resolve(spec)
	var y := float(s["hang_m"])
	var out: Array = []
	if str(s["shape"]) == "ring":
		var r0 := maxf(float(s["inner_r"]), 0.3)
		var r1 := float(s["outer_r"])
		var n := maxi(int(TAU * r1 / (BAR_PITCH_M * 4.0)), 6)
		for i in n:
			var a := TAU * (float(i) + 0.5) / float(n)
			var d := Vector3(cos(a), 0.0, sin(a))
			out.append([d * r0 + Vector3(0.0, y, 0.0), d * r1 + Vector3(0.0, y, 0.0)])
		return out
	var L := float(s["length_m"])
	var W := float(s["width_m"])
	var n2 := maxi(int(floor(W / BAR_PITCH_M)), 1)
	for i in n2:
		var z := -W * 0.5 + W * (float(i) + 0.5) / float(n2)
		out.append([Vector3(-L * 0.5 + 0.05, y, z), Vector3(L * 0.5 - 0.05, y, z)])
	return out


static func build_node(spec: Dictionary, node_name: String = "GrowLights") -> Node3D:
	var s := resolve(spec)
	var root := Node3D.new()
	root.name = node_name
	var bar := SurfaceTool.new()
	bar.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wire := SurfaceTool.new()
	wire.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := float(s["hang_m"]) + 1.0
	for b in bars(s):
		var a: Vector3 = b[0]
		var c: Vector3 = b[1]
		var dir := (c - a).normalized()
		var side := dir.cross(Vector3.UP).normalized() * BAR_W * 0.5
		var lo := Vector3(0.0, -BAR_H * 0.5, 0.0)
		EarthshipBuilder.emit_obox(bar, Transform3D(Basis(dir, Vector3.UP, side.normalized()), (a + c) * 0.5),
			Vector3((c - a).length(), BAR_H, BAR_W))
		for e in [a, c]:
			var p: Vector3 = e
			EarthshipBuilder.emit_cyl(wire, p - lo, Vector3(p.x, top, p.z), 0.002, 4)
	var mi := MeshInstance3D.new()
	mi.name = "Bars"
	mi.mesh = bar.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.18, 0.18, 0.2)
	m.emission_enabled = true
	m.emission = LIT_COLOR
	m.emission_energy_multiplier = 0.0
	mi.material_override = m
	mi.set_meta("skip_prop_collision", true)
	root.add_child(mi)
	var wi := MeshInstance3D.new()
	wi.name = "Wires"
	wi.mesh = wire.commit()
	wi.material_override = StructureMaterials.make(StructureMaterials.Kind.HARDWARE_METAL, Color(0.6, 0.6, 0.62))
	wi.set_meta("skip_prop_collision", true)
	root.add_child(wi)
	root.set_meta(KEY, s)
	return root


static func set_lit(model: Node, on: bool, strength: float = 1.0) -> void:
	if model == null:
		return
	var b := model.find_child("Bars", true, false) as MeshInstance3D
	if b == null or not (b.material_override is StandardMaterial3D):
		return
	(b.material_override as StandardMaterial3D).emission_energy_multiplier = 1.2 * clampf(strength, 0.0, 1.0) if on else 0.0


static func is_lit(model: Node) -> bool:
	var b := model.find_child("Bars", true, false) as MeshInstance3D if model != null else null
	return b != null and b.material_override is StandardMaterial3D \
		and (b.material_override as StandardMaterial3D).emission_energy_multiplier > 0.0

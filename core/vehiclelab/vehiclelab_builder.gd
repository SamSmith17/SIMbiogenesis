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
	var cutaway := bool(opts.get("cutaway", false))
	# The merged meshes of a design are built once and shared: a camp of the
	# same preset (or a map reload) does not rebuild them per vehicle.
	var key := VehicleSpec.key_of(d["spec"])
	var cached: Dictionary = _mesh_cache.get(key, {})
	if cached.is_empty():
		var gc := _kits(["frame", "tyre", "rim", "white"])
		var gb := _kits(["body", "trim", "glass", "head", "rim", "frame", "dark"])
		var sh := _kits(["body", "roof", "glass", "trim", "stripe", "door", "tail", "dark"])
		var gx := _kits(["white", "dark", "metal", "solar", "glass", "fabric", "trim", "lamp"])
		var gi := _kits(["floor", "wood", "fabric", "white", "dark", "pillow", "lamp", "mirror", "trim"])
		_chassis(d, gc)
		_cab(d, gb)
		_body(d, sh, sh)
		_exterior(d, gx)
		_floor_and_interior(d, gi)
		cached = {"Chassis": _mesh_of(gc, paint, d, "Chassis"), "Cab": _mesh_of(gb, paint, d, "Cab"),
			"Shell": _mesh_of(sh, paint, d, "Shell"), "Exterior": _mesh_of(gx, paint, d, "Exterior"),
			"Interior": _mesh_of(gi, paint, d, "Interior")}
		if _mesh_cache.size() >= MESH_CACHE_MAX:
			_mesh_cache.erase(_mesh_cache.keys()[0])
		_mesh_cache[key] = cached
	for part in ["Chassis", "Cab", "Shell", "Exterior", "Interior"]:
		if cutaway and (part == "Shell" or part == "Exterior"):
			continue
		var mesh: ArrayMesh = cached[part]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = part
		mi.mesh = mesh
		root.add_child(mi)
	_wheel_nodes(root, d, paint)
	_apply_glb_override(root, d)
	root.set_meta("living_vehicle", true)
	root.set_meta("vehicle_key", key)
	var spots: Array = []
	for bd0 in d["beds"]:
		var bd: Dictionary = bd0
		spots.append({"pos": bd["pos"], "yaw": float(bd["yaw"]), "kind": "lie",
			"length_m": float(bd["length_m"])})
	spots.append_array(d["seat_spots"])
	root.set_meta("seat_spots", spots)
	root.set_meta("role_spots", d["role_spots"])
	return root


## Rebuild ONE part of a built vehicle ("Exterior" or "Interior") from a new
## design, leaving the chassis, cab, shell and wheels as they are: what a
## furniture or roof-item drag changes. A part that was not there (the
## Exterior in a cutaway) stays absent.
static func rebuild_part(root: Node3D, d: Dictionary, part: String) -> void:
	if root == null:
		return
	var old := root.get_node_or_null(part)
	if old == null and part == "Exterior":
		return
	var paint: Dictionary = (d["spec"] as Dictionary)["paint"]
	var kits: Dictionary
	if part == "Exterior":
		kits = _kits(["white", "dark", "metal", "solar", "glass", "fabric", "trim", "lamp"])
		_exterior(d, kits)
	else:
		kits = _kits(["floor", "wood", "fabric", "white", "dark", "pillow", "lamp", "mirror", "trim"])
		_floor_and_interior(d, kits)
	var at := old.get_index() if old != null else -1
	if old != null:
		root.remove_child(old)
		old.queue_free()
	_node(root, part, kits, paint, d)
	var fresh := root.get_node_or_null(part)
	if fresh != null and at >= 0:
		root.move_child(fresh, at)


static func _kits(names: Array) -> Dictionary:
	var g := {}
	for n in names:
		g[str(n)] = _K.new()
	return g


## Built part meshes per design key (build_from_design), oldest dropped.
const MESH_CACHE_MAX := 32
static var _mesh_cache: Dictionary = {}


## A part group's merged mesh (a surface per material), null when empty.
static func _mesh_of(kits: Dictionary, paint: Dictionary, d: Dictionary, node_name: String) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for k in kits:
		_commit(kits[k], mesh, _material(str(k), paint, d, node_name))
	return mesh if mesh.get_surface_count() > 0 else null


## One MeshInstance3D per part group, a surface per material.
static func _node(root: Node3D, node_name: String, kits: Dictionary, paint: Dictionary, d: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	for k in kits:
		_commit(kits[k], mesh, _material(str(k), paint, d, node_name))
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	root.add_child(mi)


static func _material(kind: String, paint: Dictionary, d: Dictionary, node_name: String) -> Material:
	var body_c := VehicleSpec.color(paint["body"])
	match kind:
		"body":
			if node_name == "Shell":
				var wrap := wrap_material(str(paint.get("wrap", "")), d)
				if wrap != null:
					return wrap
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, body_c)
		"roof":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, VehicleSpec.color(paint["roof"]))
		"door":
			return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, body_c.darkened(0.12))
		"trim":
			return _plain(VehicleSpec.color(paint["trim"]), 0.1, 0.7)
		"glass":
			return _plain(C_GLASS, 0.3, 0.08)
		"tyre":
			return _plain(C_TYRE, 0.0, 0.9)
		"rim":
			return _plain(VehicleSpec.color(paint["wheels"]), 0.7, 0.35)
		"head":
			return _emissive(C_HEAD, 0.6)
		"tail":
			return _emissive(C_TAIL, 0.4)
		"frame":
			return _plain(C_FRAME, 0.3, 0.6)
		"stripe":
			return _plain(VehicleSpec.color(paint["stripe"]), 0.1, 0.5)
		"floor":
			return StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, C_FLOOR)
		"wood":
			return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.62, 0.49, 0.33))
		"fabric":
			return StructureMaterials.make(StructureMaterials.Kind.FABRIC, C_FABRIC)
		"white":
			return _plain(Color(0.9, 0.91, 0.92), 0.0, 0.4)
		"dark":
			return _plain(Color(0.14, 0.15, 0.17), 0.2, 0.5)
		"pillow":
			return StructureMaterials.make(StructureMaterials.Kind.FABRIC, C_PILLOW)
		"lamp":
			return _emissive(Color(1.0, 0.95, 0.82), 1.2)
		"mirror":
			return _plain(Color(0.7, 0.75, 0.8), 0.9, 0.05)
		"metal":
			return _plain(Color(0.66, 0.67, 0.69), 0.6, 0.4)
		"solar":
			return _plain(Color(0.05, 0.08, 0.17), 0.35, 0.12)
	return _plain(Color(0.6, 0.6, 0.6), 0.0, 0.6)


# --- paint wraps ------------------------------------------------------------------------

## Where the player's wrap images live (a PNG / JPG per wrap). A spec's
## `paint.wrap` is a file name in it, or a full path.
const WRAP_DIR := "user://vehicle_wraps"
static var _wrap_cache := {}


static func wrap_path(name: String) -> String:
	if name.is_empty():
		return ""
	if name.begins_with("user://") or name.begins_with("res://") or name.is_absolute_path():
		return name
	return "%s/%s" % [WRAP_DIR, name]


static func list_wraps() -> Array:
	var out: Array = []
	var dir := DirAccess.open(WRAP_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		var ext := f.get_extension().to_lower()
		if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp":
			out.append(f)
	out.sort()
	return out


## A wrap image stretched once along each side of the body (object-space
## triplanar: a side samples (z, y)), nothing tiled. null when the file is
## missing or unreadable — the body keeps its paint.
static func wrap_material(name: String, d: Dictionary) -> Material:
	var path := wrap_path(name)
	if path.is_empty():
		return null
	var tex: Texture2D = _wrap_cache.get(path, null)
	if tex == null:
		if path.begins_with("res://") and ResourceLoader.exists(path):
			tex = load(path) as Texture2D
		elif FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
		if tex == null:
			return null
		_wrap_cache[path] = tex
	var b: Dictionary = d["body"]
	var L := maxf(float(b["z1"]) - float(b["z0"]), 0.5)
	var H := maxf(float(b["h"]) - float(b["y0"]), 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_triplanar_sharpness = 8.0
	m.uv1_scale = Vector3(1.0 / L, -1.0 / H, 1.0 / L)
	m.uv1_offset = Vector3(0.5 - (float(b["z0"]) + float(b["z1"])) * 0.5 / L,
		float(b["h"]) / H, 0.5 - (float(b["z0"]) + float(b["z1"])) * 0.5 / L)
	m.roughness = 0.45
	return m


# --- a model of the real thing over the parametric one ------------------------------------

## `glb_override` {path, mode "whole" | "body", flip}: a GLB / glTF of the
## player's real vehicle (or the shipped bus / van art), turned so its long
## axis runs along Z, stretched onto the design's box and stood on the
## ground. "whole" replaces the chassis, cab and shell; "body" replaces only
## the cab and shell (the parametric wheels stay). The interior, the exterior
## items and every NPC spot stay the design's.
static var _glb_cache := {}


static func _apply_glb_override(root: Node3D, d: Dictionary) -> void:
	var ov: Variant = (d["spec"] as Dictionary).get("glb_override", {})
	if not (ov is Dictionary) or str((ov as Dictionary).get("path", "")).is_empty():
		return
	var o: Dictionary = ov
	var art := load_glb(str(o["path"]))
	if art == null:
		return
	var whole := str(o.get("mode", "whole")) != "body"
	var b: Dictionary = d["body"]
	var target := AABB()
	if whole:
		target = AABB(Vector3(-float(d["width_m"]) * 0.5, 0.0, -float(d["half_len"])),
			Vector3(float(d["width_m"]), float(d["height_m"]), float(d["length_m"])))
	else:
		var front := -float(d["half_len"])
		target = AABB(Vector3(-float(b["w"]) * 0.5, float(b["y0"]), front),
			Vector3(float(b["w"]), float(b["h"]) - float(b["y0"]), float(b["z1"]) - front))
	var holder := Node3D.new()
	holder.name = "GlbOverride"
	holder.add_child(art)
	var bb := _measure(art)
	if bb.size.length() < 0.01:
		holder.free()
		return
	var yaw := 0.0
	if bb.size.x > bb.size.z:
		yaw = PI * 0.5
	if bool(o.get("flip", false)):
		yaw += PI
	art.rotation.y = yaw
	bb = _measure_in(holder, art)
	var sc := Vector3(target.size.x / maxf(bb.size.x, 0.01), target.size.y / maxf(bb.size.y, 0.01),
		target.size.z / maxf(bb.size.z, 0.01))
	holder.scale = sc
	var c := bb.get_center()
	holder.position = target.get_center() - Vector3(c.x * sc.x, (bb.position.y + bb.size.y * 0.5) * sc.y, c.z * sc.z)
	root.add_child(holder)
	for n in (["Chassis", "Wheels", "Cab", "Shell"] if whole else ["Cab", "Shell"]):
		var node := root.get_node_or_null(n)
		if node != null:
			root.remove_child(node)
			node.free()


## The art at `path` as a fresh node (cached: a res:// scene once, a user
## file parsed once and duplicated after).
static func load_glb(path: String) -> Node3D:
	if _glb_cache.has(path):
		var cached: Node = _glb_cache[path]
		return cached.duplicate() as Node3D if is_instance_valid(cached) else null
	var node: Node3D = null
	if path.begins_with("res://"):
		if ResourceLoader.exists(path):
			var ps := load(path) as PackedScene
			if ps != null:
				node = ps.instantiate() as Node3D
	elif FileAccess.file_exists(path):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) == OK:
			node = doc.generate_scene(state) as Node3D
	if node == null:
		return null
	_glb_cache[path] = node
	return node.duplicate() as Node3D


static func _measure(n: Node3D) -> AABB:
	return _measure_in(n, n)


## The meshes under `n`, in `frame`'s space.
static func _measure_in(frame: Node3D, n: Node3D) -> AABB:
	var out := AABB()
	var found := false
	for mi0 in n.find_children("*", "MeshInstance3D", true, false):
		var mi := mi0 as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var xf := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != frame:
			if cur is Node3D:
				xf = (cur as Node3D).transform * xf
			cur = cur.get_parent()
		var box := xf * mi.mesh.get_aabb()
		out = box if not found else out.merge(box)
		found = true
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var box2 := (n as MeshInstance3D).mesh.get_aabb()
		out = box2 if not found else out.merge(box2)
	return out


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
		# A trailer's propane bottles ride the tongue (the element inside the
		# box is where the design counts them; the builder draws them here).
		if float(d.get("propane_lb", 0.0)) > 0.0:
			var wk: _K = g["white"]
			var bottles := maxi(int(round(float(d["propane_lb"]) / 20.0)), 1)
			var n_draw := mini(bottles, 2)
			for k in n_draw:
				var sx2 := (float(k) - float(n_draw - 1) * 0.5) * 0.4
				wk.cylinder(Vector3(sx2, fy + 0.35, bz0 - 0.45), 0.16, 0.6, Vector3.UP, 14)
			fk.box(Vector3(0, fy + 0.04, bz0 - 0.45), Vector3(0.9, 0.04, 0.4))


## Each wheel its own node under "Wheels", pivoting at its hub (local +X =
## the axle), so it turns as the vehicle rolls and the front ones steer
## (`spin_wheels`). The lug bolts on the hub face are what show it turning:
## 5 / 8 / 10 by the chassis' weight class (VehicleDesign.lug_count). One
## ArrayMesh per (radius, width, side) is SHARED by every wheel of that size
## — a semi's ten wheels are two meshes, not ten. A dually pair is pushed
## inside the body together, so the gap between its tyres stays.
static func _wheel_nodes(root: Node3D, d: Dictionary, paint: Dictionary) -> void:
	var hw := float((d["body"] as Dictionary)["w"]) * 0.5
	var cab_w := float((d["cab_geo"] as Dictionary)["w"]) * 0.5
	var lim := maxf(hw, cab_w)
	var holder := Node3D.new()
	holder.name = "Wheels"
	root.add_child(holder)
	var listed: Array = []
	var lugs := int(d.get("lug_count", 5))
	var meshes := {}
	# How far each (axle z, side) group must come in: the outermost tyre's
	# overhang past the body, applied to the whole group.
	var push := {}
	for w in d["wheels"]:
		var wd: Dictionary = w
		var p: Vector3 = wd["pos"]
		var tw := float(wd["w"])
		var key := "%.3f|%d" % [p.z, 1 if p.x >= 0.0 else -1]
		var over := absf(p.x) + tw * 0.5 - (lim - 0.005)
		push[key] = maxf(float(push.get(key, 0.0)), over)
	var i := 0
	for w in d["wheels"]:
		var wd: Dictionary = w
		var p: Vector3 = wd["pos"]
		var r := float(wd["r"])
		var tw := float(wd["w"])
		var side := 1.0 if p.x >= 0.0 else -1.0
		var key := "%.3f|%d" % [p.z, 1 if p.x >= 0.0 else -1]
		p.x -= side * float(push.get(key, 0.0))
		var mkey := "%.3f|%.3f|%d" % [r, tw, int(side)]
		if not meshes.has(mkey):
			var g := _kits(["tyre", "rim", "frame"])
			var tk: _K = g["tyre"]
			var rk: _K = g["rim"]
			var bk: _K = g["frame"]
			tk.cylinder(Vector3.ZERO, r, tw, Vector3.RIGHT, 22)
			rk.cylinder(Vector3(side * 0.006, 0, 0), r * 0.58, tw, Vector3.RIGHT, 16)
			rk.cylinder(Vector3(side * (tw * 0.5 + 0.01), 0, 0), r * 0.18, 0.04, Vector3.RIGHT, 10)
			for k in lugs:
				var a := TAU * float(k) / float(lugs)
				bk.box(Vector3(side * (tw * 0.5 + 0.02), cos(a) * r * 0.27, sin(a) * r * 0.27),
					Vector3(0.03, r * 0.07, r * 0.07))
			var m := ArrayMesh.new()
			for kk in g:
				_commit(g[kk], m, _material(str(kk), paint, d, "Chassis"))
			meshes[mkey] = m
		var mesh: ArrayMesh = meshes[mkey]
		var node := Node3D.new()
		node.name = "W%d" % i
		node.position = p
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = mesh
		node.add_child(mi)
		holder.add_child(node)
		listed.append({"name": node.name, "r": r, "steer": bool(wd.get("steer", false))})
		i += 1
	root.set_meta("wheel_nodes", listed)


## Turn the wheels for `roll_m` metres rolled (since the build) and steer the
## front ones by `steer_rad` (+ = to the left). Finds the wheel list on the
## vehicle's model node or the node under it.
static func spin_wheels(model: Node3D, roll_m: float, steer_rad: float = 0.0) -> void:
	# The wheel nodes are found once and kept on the model (`wheel_refs`):
	# this runs every frame for every vehicle on the move.
	var refs: Array = model.get_meta("wheel_refs", []) if model != null else []
	if refs.is_empty() or not is_instance_valid((refs[0] as Array)[0]):
		refs = _wheel_refs(model)
		if model != null:
			model.set_meta("wheel_refs", refs)
	for r in refs:
		var n: Node3D = r[0]
		if not is_instance_valid(n):
			continue
		# Forward is -Z: rolling forward turns the top of the wheel toward -Z,
		# i.e. a negative turn about +X.
		var spin := Basis(Vector3.RIGHT, -roll_m / maxf(float(r[1]), 0.05))
		n.basis = (Basis(Vector3.UP, steer_rad) * spin) if bool(r[2]) else spin


## [[node, radius, steers]] for a model's wheels.
static func _wheel_refs(model: Node3D) -> Array:
	var out: Array = []
	var root := _wheel_root(model)
	if root == null:
		return out
	var holder := root.get_node_or_null("Wheels") as Node3D
	if holder == null:
		return out
	for e in root.get_meta("wheel_nodes", []):
		var ed: Dictionary = e
		var n := holder.get_node_or_null(str(ed["name"])) as Node3D
		if n != null:
			out.append([n, float(ed["r"]), bool(ed["steer"])])
	return out


## One one-sided twin per shared material (the driver's view), kept: a
## duplicate per mount was made and never freed.
static var _one_sided: Dictionary = {}


## The driver's view: the body panels are drawn double-sided (StructureMaterials),
## so from the seat their inside faces would wall the driver in. While someone
## drives, the cab, the shell and the roof items draw one-sided (every
## triangle here winds clockwise from outside, pinned by the selftest), so the
## driver sees the road over the hood and out of the sides; from outside the
## vehicle looks the same. `on` false puts the shared materials back.
static func set_inside_view(model: Node3D, on: bool) -> void:
	var root := _wheel_root(model)
	if root == null:
		return
	for nn in ["Cab", "Shell", "Exterior", "Interior"]:
		var mi := root.get_node_or_null(nn) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			if not on:
				mi.set_surface_override_material(si, null)
				continue
			var m := mi.mesh.surface_get_material(si)
			if m is BaseMaterial3D:
				# Keyed by the source's id, checked against a weak reference (a
				# freed material's id can be reused).
				var key := m.get_instance_id()
				var hit: Array = _one_sided.get(key, [])
				var one: BaseMaterial3D = hit[1] if not hit.is_empty() and (hit[0] as WeakRef).get_ref() == m else null
				if one == null:
					one = (m as BaseMaterial3D).duplicate() as BaseMaterial3D
					one.cull_mode = BaseMaterial3D.CULL_BACK
					if _one_sided.size() > 256:
						_one_sided.clear()
					_one_sided[key] = [weakref(m), one]
				mi.set_surface_override_material(si, one)


## Front (steering) axle to the rear axles' middle, metres; 3.5 when unknown.
static func wheelbase_of(d: Dictionary) -> float:
	var zf := 0.0
	var nf := 0
	var zr := 0.0
	var nr := 0
	for w in d.get("wheels", []):
		var wd: Dictionary = w
		var z := float((wd["pos"] as Vector3).z)
		if bool(wd.get("steer", false)):
			zf += z
			nf += 1
		else:
			zr += z
			nr += 1
	if nf == 0 or nr == 0:
		return 3.5
	return absf(zr / float(nr) - zf / float(nf))


## The steering angle (rad, + = left) that turns `dyaw` over `ds` metres of
## forward travel on a bicycle model: tan(δ) = L · κ.
static func steer_for(wheelbase_m: float, dyaw: float, ds: float) -> float:
	if absf(ds) < 0.002:
		return 0.0
	return clampf(atan(wheelbase_m * dyaw / ds), -0.6, 0.6)


static func _wheel_root(model: Node3D) -> Node3D:
	if model == null:
		return null
	if model.has_meta("wheel_nodes"):
		return model
	for c in model.get_children():
		if c is Node3D and (c as Node3D).has_meta("wheel_nodes"):
			return c
	return null


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
			# The grille between the headlights, with its slats.
			var gy0 := yb + 0.5
			var gy1 := hood_top - 0.02
			(g["trim"] as _K).box(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.004), Vector3(cab_w * 0.42, gy1 - gy0, 0.02))
			for k in 3:
				(g["dark"] as _K).box(Vector3(0, gy0 + (gy1 - gy0) * (0.25 + 0.25 * float(k)), z0 - 0.016),
					Vector3(cab_w * 0.38, 0.03, 0.01))
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
		# A real headlamp: a 30 x 16 cm lens in a bezel standing 6 cm proud.
		tk.box(Vector3(sx * (bw * 0.5 - 0.22), hl_y, z0 - 0.03), Vector3(0.34, 0.2, 0.06))
		hk.box(Vector3(sx * (bw * 0.5 - 0.22), hl_y, z0 - 0.062), Vector3(0.3, 0.16, 0.01))
		var mz := z0 + hood + 0.3 if style != "forward" else z0 + 0.25
		var my := maxf(cab_h - 0.6, hood_top + 0.3) if style != "forward" else float(b["h"]) * 0.62
		tk.box(Vector3(sx * (bw * 0.5 + 0.2), my, mz), Vector3(0.05, 0.32, 0.18))
		tk.box(Vector3(sx * (bw * 0.5 + 0.1), my, mz + 0.02), Vector3(0.2, 0.025, 0.03))
	# Arches round the wheels under the cab's own panels (the cab extrusion
	# runs to cab_len whether or not the shell takes over behind it).
	_wheel_arches(d, g["dark"], cab_w * 0.5, z0, z0 + cab_len, yb)


## A dark fender box round each wheel that sits under a panel between
## `za` and `zb` (vehicle-local z) whose bottom edge `panel_y0` is below the
## tyre's top: the arch the tyre would otherwise poke through. Dually pairs
## share one arch (the outermost wheel of a side at that axle).
static func _wheel_arches(d: Dictionary, dk: _K, half_w: float, za: float, zb: float, panel_y0: float) -> void:
	var outer := {}
	for w in d["wheels"]:
		var wd: Dictionary = w
		var p: Vector3 = wd["pos"]
		var key := "%.3f|%d" % [p.z, 1 if p.x >= 0.0 else -1]
		if not outer.has(key) or absf(p.x) > absf((outer[key] as Dictionary)["pos"].x):
			outer[key] = wd
	for key in outer:
		var wd: Dictionary = outer[key]
		var p: Vector3 = wd["pos"]
		var r := float(wd["r"])
		if p.z < za + 0.05 or p.z > zb - 0.05:
			continue
		var top := r + ARCH_CLEAR_M
		if top <= panel_y0 + 0.02:
			continue
		var side := 1.0 if p.x >= 0.0 else -1.0
		var yc := (panel_y0 - 0.02 + top) * 0.5
		dk.box(Vector3(side * (half_w + 0.012), yc, p.z), Vector3(0.03, top - panel_y0 + 0.02, 2.0 * (r + ARCH_CLEAR_M)))
		# The lip of the arch over the tyre.
		dk.box(Vector3(side * (half_w + 0.03), top, p.z), Vector3(0.07, 0.025, 2.0 * (r + ARCH_CLEAR_M) + 0.02))


## The arch stands this far clear of the tyre all round.
const ARCH_CLEAR_M := 0.08


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
	var r := float(b["corner_r"])
	var crown := float(b["crown"])
	var y0 := float(b["y0"])
	var z0 := float(b["z0"])
	var z1 := float(b["z1"])
	var rake_top := float(b["rake_top"])
	var rake_from := float(b["rake_from"])
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
	# Arches round the wheels under the shell (a van's rears, a bus's).
	_wheel_arches(d, sh["dark"], hw, z0 + rake_top, z1, y0)
	# Integral bodies carry the windshield in their front face: a Class A's
	# runs from ~0.9 m over the body's bottom edge (the real 1.6 m), a bus's
	# from above its hood line.
	if integral and style != "full_van":
		var ws_lo := y0 + 0.9 if style == "forward" else floor_y + 0.85
		var ws_hi := minf(wall_top - 0.2, ws_lo + 1.3)
		var wz := z0 + _rake(ws_lo + 0.05, rake_from, H, rake_top) - 0.006
		var wz2 := z0 + _rake(ws_hi, rake_from, H, rake_top) - 0.006
		_glass_slope(sh["glass"], Vector2(wz, ws_lo), Vector2(wz2, ws_hi), hw * 1.8)
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
	# Rear lights (a 12 x 34 cm lamp in a bezel, 5 cm proud) + bumper.
	var tl: _K = g["tail"]
	for sx in [-1.0, 1.0]:
		(g["trim"] as _K).box(Vector3(sx * (hw - 0.16), y0 + 0.4, z1 + 0.025), Vector3(0.16, 0.38, 0.05))
		tl.box(Vector3(sx * (hw - 0.16), y0 + 0.4, z1 + 0.055), Vector3(0.12, 0.34, 0.01))
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


## The side panes are VehicleDesign.window_spans — the one window rule,
## which the exterior checks read too — plus a rear window on bus / band
## bodies (not on a barn-door van: its doors have them).
static func _windows(d: Dictionary, gk: _K, hw: float, floor_y: float, wall_top: float,
		_z0: float, z1: float, _style: String, _integral: bool, _rake: float) -> void:
	var kind := str((d["body"] as Dictionary)["windows"])
	if kind == "none":
		return
	for w in VehicleDesign.window_spans(d):
		var wd: Dictionary = w
		_pane(gk, float(wd["sx"]), hw, float(wd["z0"]), float(wd["z1"]), float(wd["y0"]), float(wd["y1"]))
	if kind == "bus" or kind == "band":
		var y_lo := floor_y + 0.85
		var y_hi := minf(wall_top - 0.18, floor_y + 1.75)
		if y_hi - y_lo < 0.25:
			return
		gk.quad(Vector3(-hw * 0.7, y_lo + 0.1, z1 + 0.006), Vector3(hw * 0.7, y_lo + 0.1, z1 + 0.006),
			Vector3(hw * 0.7, y_hi, z1 + 0.006), Vector3(-hw * 0.7, y_hi, z1 + 0.006), Vector3.BACK)


static func _pane(gk: _K, sx: float, hw: float, za: float, zb: float, ya: float, yb: float) -> void:
	var x := sx * (hw + 0.004)
	gk.quad(Vector3(x, ya, za), Vector3(x, ya, zb), Vector3(x, yb, zb), Vector3(x, yb, za), Vector3(sx, 0, 0))


## The step under a bus door hangs this far below its sill.
const BUS_STEP_M := 0.25


static func _doors(d: Dictionary, sh: Dictionary, hw: float, floor_y: float, y0: float,
		wall_top: float, _z0: float, z1: float, _style: String, _integral: bool) -> void:
	var b: Dictionary = d["body"]
	var dk: _K = sh["door"]
	var tk: _K = sh["trim"]
	var side := str(b["side_door"])
	var spans := VehicleDesign.door_spans(d)
	for sp in spans:
		var sd: Dictionary = sp
		if str(sd["where"]) != "side":
			continue
		var dz0 := float(sd["z0"])
		var dz1 := float(sd["z1"])
		var dy0 := float(sd["y0"])
		var dy1 := float(sd["y1"])
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
			# A step down from the door: a 25 cm tread hung under the sill.
			tk.box(Vector3(hw + 0.14, dy0 - BUS_STEP_M, (dz0 + dz1) * 0.5), Vector3(0.3, 0.05, dz1 - dz0 - 0.04))
			tk.box(Vector3(hw + 0.02, dy0 - BUS_STEP_M * 0.5, (dz0 + dz1) * 0.5), Vector3(0.03, BUS_STEP_M, dz1 - dz0 - 0.04))
		elif side == "slider" or side == "hinged":
			# A running board under the door, a hand's width out from the sill.
			tk.box(Vector3(hw + 0.1, y0 - 0.06, (dz0 + dz1) * 0.5), Vector3(0.22, 0.04, dz1 - dz0 + 0.3))
	var rear := str(b["rear_door"])
	if rear == "none":
		return
	var rz := z1 + 0.008
	var ry0 := floor_y - 0.05
	var ry1 := minf(wall_top - 0.08, floor_y + (2.2 if rear == "barn" else 2.4))
	var rw := hw - 0.08
	for sp in spans:
		var sd: Dictionary = sp
		if str(sd["where"]) == "rear":
			ry0 = float(sd["y0"])
			ry1 = float(sd["y1"])
			rw = (float(sd["x1"]) - float(sd["x0"])) * 0.5
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


# --- exterior items ------------------------------------------------------------------

static func _exterior(d: Dictionary, g: Dictionary) -> void:
	for e in d.get("exterior", []):
		_ext_element(d, e as Dictionary, g)


## One element, drawn in its own face frame (VehicleExterior.frame): x along
## u, y out of the face, z along v.
static func _ext_element(d: Dictionary, el: Dictionary, g: Dictionary) -> void:
	var fr := VehicleExterior.frame(d, el)
	if fr.is_empty():
		return
	var bas: Basis = fr["basis"]
	var base: Vector3 = fr["base"]
	var w := float(el["w"])
	var l := float(el["l"])
	var h := float(el["h"])
	var bx := bas.x.normalized()
	var by := bas.y.normalized()
	var bz := bas.z.normalized()
	var white: _K = g["white"]
	var dark: _K = g["dark"]
	var metal: _K = g["metal"]
	# A box in face coordinates: centre (cu across, cy out, cv along), size.
	var put := func(k: _K, cu: float, cy: float, cv: float, sw: float, sh: float, sl: float) -> void:
		k.obox(base + bx * cu + by * cy + bz * cv, bx * (sw * 0.5), by * (sh * 0.5), bz * (sl * 0.5))
	match str(el["type"]):
		"fan":
			put.call(white, 0.0, 0.04, 0.0, w, 0.08, l)
			# The lid, propped open toward the back.
			var lid_c := base + by * 0.14 + bz * (l * 0.08)
			var tilt := Basis(bx, -0.35)
			white.obox(lid_c, tilt * (bx * w * 0.48), tilt * (by * 0.025), tilt * (bz * l * 0.48))
			dark.obox(base + by * 0.085, bx * (w * 0.4), by * 0.006, bz * (l * 0.4))
		"vent":
			put.call(white, 0.0, 0.03, 0.0, w, 0.06, l)
			dark.obox(base + by * 0.08, bx * (w * 0.4), by * 0.025, bz * (l * 0.4))
		"ac":
			put.call(white, 0.0, h * 0.5, 0.0, w, h, l)
			for k in 4:
				var z := -l * 0.3 + float(k) * l * 0.2
				put.call(dark, 0.0, h * 0.65, z, w * 1.002, h * 0.35, 0.03)
		"starlink":
			metal.cylinder(base + by * (h * 0.4), 0.03, h * 0.8, by, 10)
			var dish := Basis(bx, -0.6)
			white.cylinder(base + by * (h * 0.85), w * 0.42, 0.04, dish * by, 20)
		"antenna":
			dark.cylinder(base + by * (h * 0.5), 0.008, h, by, 6)
			dark.cylinder(base + by * 0.03, 0.035, 0.06, by, 10)
		"gland":
			put.call(dark, 0.0, h * 0.5, 0.0, w, h, l)
		"rack":
			for su in [-1.0, 1.0]:
				put.call(metal, su * (w * 0.5 - 0.03), h * 0.75, 0.0, 0.05, 0.05, l)
				put.call(metal, su * (w * 0.5 - 0.03), h * 0.35, -l * 0.5 + 0.05, 0.04, h * 0.7, 0.04)
				put.call(metal, su * (w * 0.5 - 0.03), h * 0.35, l * 0.5 - 0.05, 0.04, h * 0.7, 0.04)
			var n := maxi(int(l / 0.6), 2)
			for i in n + 1:
				put.call(metal, 0.0, h * 0.75, -l * 0.5 + l * float(i) / float(n), w, 0.03, 0.04)
		"cargo_box":
			put.call(dark, 0.0, h * 0.45, 0.0, w, h * 0.9, l)
			put.call(dark, 0.0, h * 0.92, 0.0, w * 0.86, h * 0.1, l * 0.94)
		"solar":
			var kit_cells: _K = g["solar"]
			var mu := float(el["mod_u"])
			var mv := float(el["mod_v"])
			var cols := int(el["cols"])
			var rows := int(el["rows"])
			var flex := str(el["module"]) == "flex_100"
			var lift := 0.012 if flex else 0.07
			if not flex:
				# Two mounting rails under each row.
				for r0 in rows:
					var cv := -l * 0.5 + mv * 0.5 + float(r0) * (mv + VehicleExterior.MODULE_GAP)
					for sv in [-0.3, 0.3]:
						put.call(metal, 0.0, lift * 0.45, cv + sv * mv, w, lift * 0.9, 0.04)
			for r1 in rows:
				for c1 in cols:
					var cu := -w * 0.5 + mu * 0.5 + float(c1) * (mu + VehicleExterior.MODULE_GAP)
					var cv2 := -l * 0.5 + mv * 0.5 + float(r1) * (mv + VehicleExterior.MODULE_GAP)
					var t := 0.004 if flex else 0.035
					put.call(kit_cells, cu, lift + t * 0.5, cv2, mu - 0.01, t, mv - 0.01)
					if not flex:
						put.call(metal, cu, lift + t * 0.5, cv2, mu, t * 0.9, mv)
		"awning":
			# The roll along the top of the wall; rolled out, the canvas slopes
			# away and two legs hold its front edge.
			metal.cylinder(base + by * 0.09, 0.08, w, bx, 12)
			if bool(el.get("open", false)):
				var ext := float(el.get("ext", 2.4))
				var fab: _K = g["fabric"]
				var a0 := base + by * 0.1 - bx * (w * 0.5)
				var a1 := base + by * 0.1 + bx * (w * 0.5)
				var b0 := a0 + by * ext - bz * 0.35
				var b1 := a1 + by * ext - bz * 0.35
				fab.quad(a0, a1, b1, b0, (by * 0.35 + bz * ext).normalized())
				fab.quad(a0, b0, b1, a1, -(by * 0.35 + bz * ext).normalized())
				var foot := 0.0   # the ground under the vehicle
				for p in [b0, b1]:
					var pp: Vector3 = p
					metal.cylinder(Vector3(pp.x, (pp.y + foot) * 0.5, pp.z), 0.02, pp.y - foot, Vector3.UP, 8)
		"ladder":
			var top := float(d["body"]["h"]) - base.y
			var bottom := float(d["body"]["y0"]) - base.y
			for su in [-1.0, 1.0]:
				put.call(metal, su * w * 0.5, 0.06, (top + bottom) * 0.5, 0.03, 0.03, top - bottom)
			var rungs := maxi(int((top - bottom) / 0.3), 2)
			for i in rungs + 1:
				put.call(metal, 0.0, 0.06, bottom + (top - bottom) * float(i) / float(rungs), w, 0.025, 0.025)
		"light_bar":
			put.call(dark, 0.0, h * 0.5, 0.0, w, h, l)
			put.call(g["lamp"], 0.0, h * 0.5, -l * 0.5 - 0.004, w * 0.95, h * 0.6, 0.008)
		"bike_rack":
			put.call(metal, 0.0, 0.25, 0.0, 0.06, 0.5, 0.06)
			put.call(metal, 0.0, h, 0.0, w, 0.05, 0.05)
			put.call(metal, 0.0, h * 0.6, l * 0.35, w * 0.9, 0.04, 0.04)
		"window":
			put.call(g["glass"], 0.0, 0.012, 0.0, w, 0.01, l)
			put.call(g["trim"], 0.0, 0.006, 0.0, w + 0.06, 0.008, l + 0.06)
		"hitch":
			put.call(dark, 0.0, h * 0.5, 0.0, w, h, l)
			put.call(metal, 0.0, h + 0.03, 0.0, 0.03, 0.06, 0.03)
		_:
			put.call(dark, 0.0, h * 0.5, 0.0, w, h, l)


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
	var trailer := str(d["cab"]) == "none"
	for e in d["interior"]:
		# A trailer's propane bottles ride its tongue (drawn by _chassis).
		if trailer and str((e as Dictionary)["type"]) == "propane":
			continue
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
		"battery", "heater":
			dark.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"inverter", "shore_inlet":
			(g["trim"] as _K).box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"water_tank", "grey_tank", "water_heater":
			white.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"black_tank":
			dark.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
		"propane":
			# Two upright bottles side by side along the element's long side.
			var along := fz >= fx
			var rr := minf(fx, fz) * 0.45
			for k in [-1.0, 1.0]:
				var c := Vector3(x, (y0 + y1) * 0.5, z + k * fz * 0.25) if along \
					else Vector3(x + k * fx * 0.25, (y0 + y1) * 0.5, z)
				white.cylinder(c, rr, y1 - y0, Vector3.UP, 14)
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

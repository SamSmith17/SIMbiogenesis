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
const C_AMBER := Color(0.95, 0.55, 0.08)
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
		var gc := _kits(["frame", "tyre", "rim", "white", "metal", "dark"])
		var gb := _kits(["body", "trim", "glass", "head", "rim", "frame", "dark", "amber", "metal", "seat", "white"])
		var sh := _kits(["body", "roof", "glass", "trim", "stripe", "door", "tail", "dark", "amber", "liner",
			"metal", "white", "lamp"])
		var gx := _kits(["white", "dark", "metal", "solar", "glass", "fabric", "trim", "lamp"])
		var gi := _kits(["floor", "wood", "fabric", "white", "dark", "pillow", "lamp", "mirror", "trim", "seat", "metal"])
		# Every see-through pane (the cab's and the body's) is one mesh of its
		# own, "Glass": it casts no shadow, so the sun reaches the room.
		var gl := _kits(["pane"])
		gb["pane"] = gl["pane"]
		sh["pane"] = gl["pane"]
		_chassis(d, gc)
		_cab(d, gb)
		_body(d, sh, sh)
		_exterior(d, gx)
		_floor_and_interior(d, gi)
		gb.erase("pane")
		sh.erase("pane")
		var leaves: Array = []
		for lf0 in _door_leaves(d):
			var lf: Dictionary = lf0
			var lm := _mesh_of(lf["kits"], paint, d, "Door")
			if lm != null:
				leaves.append({"name": lf["name"], "mesh": lm, "open": lf["open"], "door": lf["door"],
					"where": lf["where"], "kind": lf["kind"]})
		cached = {"Chassis": _mesh_of(gc, paint, d, "Chassis"), "Cab": _mesh_of(gb, paint, d, "Cab"),
			"Shell": _mesh_of(sh, paint, d, "Shell"), "Glass": _mesh_of(gl, paint, d, "Glass"),
			"Exterior": _mesh_of(gx, paint, d, "Exterior"),
			"Interior": _mesh_of(gi, paint, d, "Interior"), "Doors": leaves,
			"Collision": _collision_mesh(d)}
		if _mesh_cache.size() >= MESH_CACHE_MAX:
			_mesh_cache.erase(_mesh_cache.keys()[0])
		_mesh_cache[key] = cached
	for part in PARTS:
		if cutaway and CUTAWAY_HIDES.has(part):
			continue
		var mesh: ArrayMesh = cached[part]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = part
		mi.mesh = mesh
		# The walk-in collision is its own simple mesh (below): the drawn
		# parts never become colliders.
		mi.set_meta("skip_prop_collision", true)
		if part == "Glass":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	if not cutaway:
		var holder := Node3D.new()
		holder.name = "Doors"
		root.add_child(holder)
		for lf1 in cached["Doors"]:
			var le: Dictionary = lf1
			var dn := MeshInstance3D.new()
			dn.name = str(le["name"])
			dn.mesh = le["mesh"]
			dn.set_meta("skip_prop_collision", true)
			dn.set_meta("open_xf", le["open"])
			dn.set_meta("door", int(le["door"]))
			dn.set_meta("where", str(le["where"]))
			dn.set_meta("kind", str(le["kind"]))
			holder.add_child(dn)
	var col: ArrayMesh = cached["Collision"]
	if col != null:
		var cm := MeshInstance3D.new()
		cm.name = "CollisionMesh"
		cm.mesh = col
		cm.visible = false
		root.add_child(cm)
	root.set_meta("door_gaps", door_gaps(d))
	var hs: Dictionary = d["house"]
	root.set_meta("house_box", {"z0": float(hs["z0"]), "z1": float(hs["z1"]), "w": float(hs["w"]),
		"floor_y": float(hs["floor_y"]), "ceil_y": float(hs["ceil_y"])})
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
		kits = _kits(["floor", "wood", "fabric", "white", "dark", "pillow", "lamp", "mirror", "trim", "seat", "metal"])
		_floor_and_interior(d, kits)
	var at := old.get_index() if old != null else -1
	if old != null:
		root.remove_child(old)
		old.queue_free()
	_node(root, part, kits, paint, d)
	var fresh := root.get_node_or_null(part)
	if fresh != null:
		fresh.set_meta("skip_prop_collision", true)
	if fresh != null and at >= 0:
		root.move_child(fresh, at)


static func _kits(names: Array) -> Dictionary:
	var g := {}
	for n in names:
		g[str(n)] = _K.new()
	return g


## The drawn parts, in draw order; a cutaway leaves the skin off.
const PARTS := ["Chassis", "Cab", "Shell", "Glass", "Exterior", "Interior"]
const CUTAWAY_HIDES := ["Shell", "Glass", "Exterior"]

## Built part meshes per design key (build_from_design), oldest dropped.
const MESH_CACHE_MAX := 32
static var _mesh_cache: Dictionary = {}


## A part group's merged mesh (a surface per material), null when empty.
static func _mesh_of(kits: Dictionary, paint: Dictionary, d: Dictionary, node_name: String) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for k in kits:
		_commit(kits[k], mesh, _material(str(k), paint, d, node_name))
	return mesh if mesh.get_surface_count() > 0 else null


## Car paint: a base coat under a clear coat (the gloss that makes a panel
## read as a vehicle's, not a wall's). Double-sided, like every body panel.
static func _paint(c: Color) -> StandardMaterial3D:
	return ParametricMaterialLibrary.make("car_paint", c)


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
			if node_name == "Shell" or node_name == "Door":
				var wrap := wrap_material(str(paint.get("wrap", "")), d)
				if wrap != null:
					return wrap
				var lv := livery_material(paint, d)
				if lv != null:
					return lv
			return _paint(body_c)
		"roof":
			return _paint(VehicleSpec.color(paint["roof"]))
		"door":
			return _paint(body_c.darkened(0.1))
		"trim":
			return _plain(VehicleSpec.color(paint["trim"]), 0.1, 0.62)
		"glass":
			var gm := _plain(C_GLASS, 0.35, 0.06)
			gm.clearcoat_enabled = true
			gm.clearcoat = 1.0
			gm.clearcoat_roughness = 0.03
			return gm
		"pane":
			# Tinted, see-through from both sides.
			var pm := _plain(Color(0.06, 0.09, 0.11, 0.58), 0.3, 0.05)
			pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			pm.cull_mode = BaseMaterial3D.CULL_DISABLED
			pm.metallic_specular = 0.9
			return pm
		"liner":
			var lm := _plain(Color(0.86, 0.85, 0.81), 0.0, 0.85)
			lm.cull_mode = BaseMaterial3D.CULL_DISABLED
			return lm
		"seat":
			return StructureMaterials.make(StructureMaterials.Kind.FABRIC, Color(0.2, 0.21, 0.24))
		"tyre":
			return _plain(C_TYRE, 0.0, 0.92)
		"rim":
			return _plain(VehicleSpec.color(paint["wheels"]), 0.75, 0.3)
		"head":
			return _emissive(C_HEAD, 0.6)
		"tail":
			return _emissive(C_TAIL, 0.4)
		"amber":
			return _emissive(C_AMBER, 0.5)
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
	return _triplanar_body(tex, d)


## A texture laid over the body by object-space triplanar: a side samples
## (z, y) — the image's left edge at the rear, its right edge at the front,
## its top row at the roof, its bottom row at the body's bottom edge — and
## the ends sample (x, y) from the image's middle.
static func _triplanar_body(tex: Texture2D, d: Dictionary) -> Material:
	var b: Dictionary = d["body"]
	var L := maxf(float(b["z1"]) - float(b["z0"]), 0.5)
	var H := maxf(float(b["h"]) - float(b["y0"]), 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_triplanar_sharpness = 8.0
	# Godot's triplanar already flips the vertical (it samples -pos.y), so
	# +1/H here puts the image's top row on the roof. (-1/H put every wrap
	# on upside down until 2026-11-03.)
	m.uv1_scale = Vector3(1.0 / L, 1.0 / H, 1.0 / L)
	m.uv1_offset = Vector3(0.5 - (float(b["z0"]) + float(b["z1"])) * 0.5 / L,
		-float(b["h"]) / H, 0.5 - (float(b["z0"]) + float(b["z1"])) * 0.5 / L)
	m.metallic = 0.12
	m.roughness = 0.36
	m.clearcoat_enabled = true
	m.clearcoat = 0.7
	m.clearcoat_roughness = 0.12
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# --- liveries ----------------------------------------------------------------------------

static var _livery_cache := {}


## The paint's livery (VehicleSpec.LIVERIES) as a material over the body:
## an image painted from the scheme and laid on like a wrap. null = none.
static func livery_material(paint: Dictionary, d: Dictionary) -> Material:
	var kind := str(paint.get("livery", ""))
	if kind.is_empty():
		return null
	var b: Dictionary = d["body"]
	var y0 := float(b["y0"])
	var span := maxf(float(b["h"]) - y0, 0.5)
	# The window line (where a transit scheme's top colour stops at the rear,
	# and a two-tone's lower colour reaches), as a share of the side's height.
	var line := clampf((float(b["floor_y"]) + 0.55 - y0) / span, 0.15, 0.85)
	var key := "%s|%s|%s|%s|%.3f" % [kind, str(paint.get("body")), str(paint.get("livery_a")),
		str(paint.get("livery_b")), line]
	var tex: Texture2D = _livery_cache.get(key, null)
	if tex == null:
		var img := livery_image(kind, VehicleSpec.color(paint["body"]),
			VehicleSpec.color(paint.get("livery_a", [0.1, 0.3, 0.6])),
			VehicleSpec.color(paint.get("livery_b", [0.9, 0.8, 0.4])), line)
		tex = ImageTexture.create_from_image(img)
		if _livery_cache.size() > 16:
			_livery_cache.clear()
		_livery_cache[key] = tex
	return _triplanar_body(tex, d)


## The livery painted column by column (x = 0 the rear, the right edge the
## front; row 0 the roof). transit: colour A over the rear's top down to the
## window line, sweeping up to the roof over the front third (TriMet's
## diagonal through the lift doors), and a colour B swoosh along the bottom
## of the rear that thins out toward the front. two_tone: B below the line
## with a thin A pinstripe over it.
static func livery_image(kind: String, base: Color, a: Color, b: Color, line: float) -> Image:
	var W := 1024
	var Hh := 256
	var img := Image.create(W, Hh, false, Image.FORMAT_RGBA8)
	img.fill(base)
	for x in W:
		var f := (float(x) + 0.5) / float(W)
		match kind:
			"transit":
				var ha := 2.0
				if f <= 0.57:
					ha = line
				elif f <= 0.81:
					ha = line + (1.0 - line) * (f - 0.57) / 0.24
				if ha < 1.0:
					img.fill_rect(Rect2i(x, 0, 1, int(round((1.0 - ha) * Hh))), a)
				var hb := line * 0.62 * (1.0 - smoothstep(0.45, 0.8, f))
				var rb := int(round(hb * Hh))
				if rb > 0:
					img.fill_rect(Rect2i(x, Hh - rb, 1, rb), b)
			"two_tone":
				var lo := line * 0.75
				var rb2 := int(round(lo * Hh))
				img.fill_rect(Rect2i(x, Hh - rb2, 1, rb2), b)
				var p0 := int(round((1.0 - lo - 0.045) * Hh))
				var p1 := int(round((1.0 - lo - 0.02) * Hh))
				img.fill_rect(Rect2i(x, p0, 1, maxi(p1 - p0, 1)), a)
	img.generate_mipmaps()
	return img


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
	# The art is never a collider (the walk-in collision mesh stays the
	# design's), and it replaces the drawn glass and door leaves too.
	for am in holder.find_children("*", "MeshInstance3D", true, false):
		(am as Node).set_meta("skip_prop_collision", true)
	for n in (["Chassis", "Wheels", "Cab", "Shell", "Glass", "Doors"] if whole else ["Cab", "Shell", "Glass", "Doors"]):
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
			var g := _kits(["tyre", "rim", "frame", "metal"])
			var tk: _K = g["tyre"]
			var rk: _K = g["rim"]
			var bk: _K = g["frame"]
			var ax := Vector3.RIGHT * side
			var h := tw * 0.5
			# The tyre: sidewalls bulging to rounded shoulders, a flat tread
			# with grooves; the rim: a lip, a dish, the disc with hand holes,
			# the hub with its lugs.
			tk.lathe(Vector3.ZERO, ax, PackedVector2Array([Vector2(-h, r * 0.6), Vector2(-h, r * 0.86),
				Vector2(-h * 0.9, r * 0.95), Vector2(-h * 0.7, r), Vector2(h * 0.7, r), Vector2(h * 0.9, r * 0.95),
				Vector2(h, r * 0.86), Vector2(h, r * 0.62)]), 28)
			for gx in [-0.3, 0.0, 0.3]:
				bk.lathe(Vector3.ZERO, ax, PackedVector2Array([Vector2(h * gx - 0.008, r + 0.001), Vector2(h * gx + 0.008, r + 0.001)]), 28)
			bk.lathe(Vector3.ZERO, ax, PackedVector2Array([Vector2(-h, 0.0), Vector2(-h, r * 0.6)]), 20)
			var dish := minf(0.07, tw * 0.3)
			rk.lathe(Vector3.ZERO, ax, PackedVector2Array([Vector2(h, r * 0.62), Vector2(h + 0.012, r * 0.6),
				Vector2(h + 0.012, r * 0.57), Vector2(h - dish, r * 0.5), Vector2(h - dish - 0.01, r * 0.22),
				Vector2(h - dish + 0.03, r * 0.2), Vector2(h - dish + 0.045, r * 0.11), Vector2(h - dish + 0.045, 0.0)]), 22)
			var holes := 8 if lugs >= 8 else 6
			for k in holes:
				var a := TAU * (float(k) + 0.5) / float(holes)
				bk.cylinder(ax * (h - dish - 0.004) + Vector3(0, cos(a), sin(a)) * r * 0.37, r * 0.075, 0.006, ax, 8)
			for k in lugs:
				var a := TAU * float(k) / float(lugs)
				(g["metal"] as _K).cylinder(ax * (h - dish + 0.035) + Vector3(0, cos(a), sin(a)) * r * 0.155, r * 0.028, 0.03, ax, 6)
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
		mi.set_meta("skip_prop_collision", true)
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
	var nodes: Array = [root.get_node_or_null("Cab"), root.get_node_or_null("Shell"),
		root.get_node_or_null("Exterior"), root.get_node_or_null("Interior")]
	var doors := root.get_node_or_null("Doors")
	if doors != null:
		nodes.append_array(doors.get_children())
	for n0 in nodes:
		var mi := n0 as MeshInstance3D
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

## The front of the vehicle per cab style: a van / cutaway nose and a
## cab-over are lofted through rounded cross-sections with the windshield and
## the door glass as real panes in the loft; a conventional hood (a school
## bus) is lofted with fenders over its wheels; then the bumper, grille,
## lamps, mirrors, wipers, and the seats, dash and wheel behind the glass.
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
	var tk: _K = g["trim"]
	var dk: _K = g["dark"]
	var hk: _K = g["head"]
	var ak: _K = g["amber"]
	var mk: _K = g["metal"]
	var integral := bool(cg["integral"])
	var hood_top := fy + 0.55
	var bw := maxf(cab_w, float(b["w"]) if integral else cab_w)
	match style:
		"full_van", "cutaway":
			_van_cab(d, g)
		"cowl":
			hood_top = fy + 0.75
			_hood_loft(d, g, cab_w * 0.84, hood_top)
			if not integral:
				var cp := PackedVector2Array([Vector2(z0 + hood, yb), Vector2(z0 + hood, hood_top + 0.05),
					Vector2(z0 + hood + 0.2, cab_h), Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
				_extrude_side(bk, cp, cab_w)
				_glass_slope(gk, Vector2(z0 + hood + 0.02, hood_top + 0.12),
					Vector2(z0 + hood + 0.18, cab_h - 0.08), cab_w * 0.9)
				_side_windows(gk, z0 + hood + 0.3, z0 + cab_len - 0.3, hood_top + 0.2, cab_h - 0.12, cab_w)
		"forward":
			if not integral:
				_cabover_cab(d, g)
		"tractor":
			hood_top = fy + 0.9
			_hood_loft(d, g, cab_w * 0.86, hood_top)
			var cp2 := PackedVector2Array([Vector2(z0 + hood, yb), Vector2(z0 + hood, hood_top + 0.08),
				Vector2(z0 + hood + 0.3, cab_h), Vector2(z0 + cab_len, cab_h), Vector2(z0 + cab_len, yb)])
			_extrude_side(bk, cp2, cab_w)
			_glass_slope(gk, Vector2(z0 + hood + 0.03, hood_top + 0.15),
				Vector2(z0 + hood + 0.27, cab_h - 0.1), cab_w * 0.9)
			_side_windows(gk, z0 + hood + 0.35, z0 + cab_len - 0.4, hood_top + 0.25, cab_h - 0.15, cab_w)
			# Exhaust stacks.
			for sx in [-1.0, 1.0]:
				mk.cylinder(Vector3(sx * (cab_w * 0.5 - 0.12), cab_h + 0.5, z0 + cab_len + 0.08),
					0.07, 1.6, Vector3.UP, 10)
	var van_nose := style == "full_van" or style == "cutaway"
	var hooded := style == "cowl" or style == "tractor"
	# --- bumper: a bar with wrapped ends, an air dam under it, the plate ---
	var by := yb + 0.12
	var bz := z0 - 0.07
	var bcol: _K = mk if style == "tractor" else tk
	bcol.box(Vector3(0, by, bz), Vector3(bw * 0.9, 0.24, 0.16))
	for sx in [-1.0, 1.0]:
		var ex: float = sx * bw * 0.47
		bcol.obox(Vector3(ex, by, bz + 0.05), Vector3(0.07, 0, 0.05), Vector3(0, 0.12, 0), Vector3(-sx * 0.06, 0, 0.1))
	dk.box(Vector3(0, by - 0.16, bz + 0.05), Vector3(bw * 0.8, 0.09, 0.08))
	(g["white"] as _K).box(Vector3(0, by, bz - 0.083), Vector3(0.31, 0.155, 0.006))
	# --- lamps, grille and mirrors where the loft did not draw its own ---
	if not van_nose:
		var hl_y := yb + 0.5
		if style == "forward":
			hl_y = (float(b["y0"]) + 0.5) if integral else (fy + 0.26)
		var hx := bw * 0.5 - 0.24 if not hooded else cab_w * 0.5 - 0.2
		var fz := z0 - 0.004
		for sx in [-1.0, 1.0]:
			var x: float = sx * hx
			if hooded:
				# Round lamps in pods on the fenders.
				tk.cylinder(Vector3(x, hl_y, fz + 0.02), 0.13, 0.12, Vector3.FORWARD, 14)
				hk.cylinder(Vector3(x, hl_y, fz - 0.045), 0.105, 0.012, Vector3.FORWARD, 14)
				ak.box(Vector3(x, hl_y - 0.2, fz - 0.02), Vector3(0.16, 0.06, 0.03))
			else:
				tk.box(Vector3(x, hl_y, fz - 0.02), Vector3(0.36, 0.2, 0.05))
				hk.box(Vector3(x - sx * 0.05, hl_y, fz - 0.048), Vector3(0.22, 0.15, 0.01))
				ak.box(Vector3(x + sx * 0.13, hl_y, fz - 0.048), Vector3(0.07, 0.15, 0.01))
			# West-coast mirrors on tube arms.
			var mz := z0 + hood + 0.3 if style != "forward" else z0 + 0.22
			var my := maxf(cab_h - 0.55, hood_top + 0.45) if style != "forward" else float(b["h"]) * 0.62
			var mxo := bw * 0.5 + 0.24
			for dy in [-0.16, 0.16]:
				mk.box(Vector3(sx * (bw * 0.5 + 0.12), my + dy, mz + 0.03), Vector3(0.24, 0.02, 0.02))
			dk.box(Vector3(sx * mxo, my, mz), Vector3(0.05, 0.36, 0.17))
			(g["rim"] as _K).box(Vector3(sx * mxo, my, mz + 0.087), Vector3(0.04, 0.32, 0.004))
		if style == "forward":
			# A flat-front grille panel between the lamps, and the wiper cowl.
			dk.box(Vector3(0, hl_y, fz - 0.01), Vector3(bw * 0.42, 0.2, 0.02))
			for k in 3:
				tk.box(Vector3(0, hl_y - 0.06 + 0.06 * float(k), fz - 0.022), Vector3(bw * 0.4, 0.014, 0.01))
	if hooded and integral:
		_wheel_arches(d, dk, cab_w * 0.5, z0 + hood, z0 + cab_len, yb)
	_cab_interior(d, g)


## A conventional hood (a school bus, a tractor): a tapered loft from the
## grille to the cowl, a slatted grille in a bright surround, and a fender
## arched over each front wheel.
static func _hood_loft(d: Dictionary, g: Dictionary, w: float, hood_top: float) -> void:
	var cg: Dictionary = d["cab_geo"]
	var z0 := float(cg["z0"])
	var hood := float(cg["hood"])
	var fy := float(cg["frame_h"])
	var yb := maxf(fy - 0.32, 0.28)
	var hw := w * 0.5
	var keys := [
		[0.0, hw * 0.6, yb + 0.14, hood_top - 0.34, 0.08, 0.04],
		[0.07, hw * 0.66, yb + 0.06, hood_top - 0.24, 0.16, 0.05],
		[0.35, hw * 0.72, yb, hood_top - 0.14, 0.22, 0.05],
		[hood * 0.7, hw * 0.8, yb, hood_top - 0.02, 0.24, 0.05],
		[hood, hw * 0.86, yb, hood_top + 0.05, 0.2, 0.05]]
	var rings: Array = []
	for kd in keys:
		rings.append(_rr_ring(float(kd[1]), float(kd[2]), float(kd[3]), float(kd[4]), float(kd[5]), z0 + float(kd[0])))
	_loft(rings, func(_k, _i): return g["body"], Callable(), g["body"])
	# Grille: a dark field of slats in a bright surround.
	var gy0 := yb + 0.3
	var gy1 := hood_top - 0.42
	var gw := hw * 0.95
	(g["metal"] as _K).box(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.006), Vector3(gw + 0.06, gy1 - gy0 + 0.06, 0.02))
	(g["dark"] as _K).box(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.014), Vector3(gw, gy1 - gy0, 0.012))
	var ns := maxi(int((gy1 - gy0) / 0.07), 3)
	for k in ns:
		(g["metal"] as _K).box(Vector3(0, gy0 + (gy1 - gy0) * (float(k) + 0.5) / float(ns), z0 - 0.022), Vector3(gw, 0.02, 0.008))
	# Fenders: a band arched over each front tyre from the hood's side out to
	# the body's width, with a lip round its rim.
	var axles: Array = d["axles"]
	var wheels: Array = d["wheels"]
	if axles.is_empty() or wheels.is_empty():
		return
	var zc := z0 + float((axles[0] as Dictionary)["zf"])
	var r := float((wheels[0] as Dictionary)["r"])
	var R := r + ARCH_CLEAR_M + 0.02
	var xo := float(cg["w"]) * 0.5
	var xi := hw * 0.7
	var bk: _K = g["body"]
	var steps := 12
	for sx in [-1.0, 1.0]:
		for m in steps:
			var t0 := lerpf(deg_to_rad(200.0), deg_to_rad(-20.0), float(m) / float(steps))
			var t1 := lerpf(deg_to_rad(200.0), deg_to_rad(-20.0), float(m + 1) / float(steps))
			var p0 := Vector2(zc + R * cos(t0), r + R * sin(t0))
			var p1 := Vector2(zc + R * cos(t1), r + R * sin(t1))
			var nrm := Vector3(0, sin((t0 + t1) * 0.5), cos((t0 + t1) * 0.5))
			bk.quad(Vector3(sx * xi, p0.y, p0.x), Vector3(sx * xo, p0.y, p0.x), Vector3(sx * xo, p1.y, p1.x),
				Vector3(sx * xi, p1.y, p1.x), nrm)
			# The fender's outer skirt down to the arch.
			var q0 := Vector2(zc + (R - 0.07) * cos(t0), r + (R - 0.07) * sin(t0))
			var q1 := Vector2(zc + (R - 0.07) * cos(t1), r + (R - 0.07) * sin(t1))
			bk.quad(Vector3(sx * xo, p0.y, p0.x), Vector3(sx * xo, p1.y, p1.x), Vector3(sx * xo, q1.y, q1.x),
				Vector3(sx * xo, q0.y, q0.x), Vector3(sx, 0, 0))
		_well(g["dark"], xo - 0.005, zc, r, R - 0.07, r - R * 0.34, xo - xi)


## The hood's drawn length: a full van's (a Sprinter's, a Transit's) nose is
## shorter than the chassis' cab-to-axle figure suggests: its windshield
## starts well ahead of the driver.
static func nose_hood(d: Dictionary) -> float:
	var cg: Dictionary = d["cab_geo"]
	var hood := float(cg["hood"])
	if str(cg["style"]) == "full_van" and bool(cg["integral"]):
		return maxf(hood - 0.27, 0.5)
	return hood


## A van's nose and cab (an E-series cutaway, a Sprinter, a Transit) lofted
## through rounded cross-sections: the grille face, the hood falling to it,
## the cowl, the windshield's rake, the roof and the cab's back. The
## sections' bottom rises round the front wheel (the arch), the windshield
## and the door glass are panes IN the loft (see-through, flush), and a
## full van's cab is open at the back into the body it is part of.
static func _van_cab(d: Dictionary, g: Dictionary) -> void:
	var cg: Dictionary = d["cab_geo"]
	var b: Dictionary = d["body"]
	var z0 := float(cg["z0"])
	var hood := nose_hood(d)
	var cab_len := float(cg["cab_len"])
	var ch := float(cg["h"])
	var W := float(cg["w"])
	var fy := float(cg["frame_h"])
	var yb := maxf(fy - 0.32, 0.28)
	var open_back := bool(cg["integral"])
	if open_back:
		cab_len = clampf(float(b["z0"]) - z0 + 0.03, hood + 0.9, cab_len)
	# A Euro van's nose (a Sprinter, a Transit) is short and steep: the hood
	# climbs to a high cowl and the windshield carries on at nearly the same
	# rake. A cutaway keeps the E-series' long flat hood.
	var euro := open_back
	var gt := fy + (0.44 if euro else 0.36)
	var ct := fy + (0.74 if euro else 0.6)
	var ws_end := minf(hood + (0.72 if euro else 0.64), cab_len - 0.2)
	var roof_u := minf(ws_end + 0.14, cab_len - 0.06)
	var belt := fy + (0.92 if euro else 0.8)
	var keys := [
		[0.0, W * 0.4, yb + 0.06, gt - 0.03, 0.08, 0.05],
		[0.07, W * 0.45, yb, gt, 0.15, 0.06],
		[0.4, W * 0.49, yb, gt + (ct - gt) * (0.5 if euro else 0.35), 0.22, 0.06],
		[hood, W * 0.5, yb, ct, 0.2, 0.06],
		[ws_end, W * 0.5, yb, ch - 0.04, 0.16, 0.06],
		[roof_u, W * 0.5, yb, ch, 0.12, 0.06],
		[cab_len, W * 0.5, yb, ch, 0.12, 0.06]]
	# Where the A-pillar's foot crosses the belt line: the door glass starts
	# just behind it.
	var f0 := ct - 0.2
	var f1 := ch - 0.04 - 0.16
	var u_belt := hood + clampf((belt - f0) / maxf(f1 - f0, 0.05), 0.0, 1.0) * (ws_end - hood)
	var ua := u_belt + 0.03
	# A full van's door glass runs back to the body, where the body's own
	# wall carries on with it (VehicleBuilder._body).
	var ub := (cab_len - 0.04) if open_back else minf(cab_len - 0.1, hood + 1.02)
	var ws0 := hood + 0.05
	var ws1 := ws_end - 0.05
	var fo := -1.0
	var r := 0.0
	var axles: Array = d["axles"]
	if not axles.is_empty() and not (d["wheels"] as Array).is_empty():
		fo = float((axles[0] as Dictionary)["zf"])
		r = float((d["wheels"] as Array)[0]["r"])
	var R := r + ARCH_CLEAR_M
	var us: Array = [ua, ub, ws0, ws1]
	for kd in keys:
		us.append(float(kd[0]))
	if fo > 0.0:
		for m in 11:
			us.append(fo + R * cos(PI * float(m) / 10.0))
	us.sort()
	var rings: Array = []
	var ru: Array = []
	var last := -1.0
	for u0 in us:
		var u := clampf(float(u0), 0.0, cab_len)
		if u - last < 0.01:
			continue
		last = u
		var kp := _key_lerp(keys, u)
		var ybot := float(kp[2])
		if fo > 0.0 and absf(u - fo) < R:
			ybot = maxf(ybot, r + sqrt(R * R - (u - fo) * (u - fo)))
		rings.append(_rr_ring(float(kp[1]), ybot, float(kp[3]), float(kp[4]), float(kp[5]), z0 + u, belt))
		ru.append(u)
	var kit_of := func(k: int, i: int) -> _K:
		var a := float(ru[k])
		var c := float(ru[k + 1])
		if (i == RR_TOP_R or i == RR_TOP_L) and a >= ws0 - 1e-4 and c <= ws1 + 1e-4:
			return g["pane"]
		if (i == RR_WIN_R or i == RR_WIN_L) and a >= ua - 1e-4 and c <= ub + 1e-4:
			return g["pane"]
		return g["body"]
	_loft(rings, kit_of, Callable(), g["body"], not open_back)
	var hw := W * 0.5
	if fo > 0.0:
		_well(g["dark"], hw, z0 + fo, r, R, yb, 0.42)
		_arch_lip(g["trim"], hw - 0.004, z0 + fo, r, R, yb)
	var slope := (ch - 0.04 - ct) / maxf(ws_end - hood, 0.1)
	var tk: _K = g["trim"]
	var dk: _K = g["dark"]
	var whi := ch - 0.17
	var zr := z0 + ub
	# The black band round the windshield and two wipers parked on the cowl.
	var wsx := hw - 0.19
	for e in [[ws0, ct + slope * 0.05, 0.04], [ws1, ch - 0.04 - slope * 0.05, 0.03]]:
		dk.box(Vector3(0, float(e[1]) + 0.004, z0 + float(e[0])), Vector3(wsx * 2.0, 0.012, float(e[2])))
	for sx in [-1.0, 1.0]:
		var w0 := Vector3(sx * 0.12 - 0.3, ct + slope * 0.09 + 0.012, z0 + hood + 0.09)
		var w1 := Vector3(sx * 0.12 + 0.3, ct + slope * 0.13 + 0.012, z0 + hood + 0.13)
		dk.obox((w0 + w1) * 0.5, (w1 - w0) * 0.5, Vector3(0, 0.006, 0), Vector3(0, 0, 0.01))
	for sx in [-1.0, 1.0]:
		var x: float = sx * (hw + 0.003)
		# The door: its shut lines, the belt moulding, the handle, a step.
		dk.box(Vector3(x, belt - 0.012, (z0 + ua + zr) * 0.5), Vector3(0.008, 0.024, zr - z0 - ua + 0.04))
		tk.box(Vector3(x, (yb + belt) * 0.5 + 0.12, z0 + maxf(hood + 0.06, (fo + R + 0.03) if fo > 0.0 else 0.0)), Vector3(0.006, belt - yb - 0.3, 0.012))
		if not open_back:
			tk.box(Vector3(x, (yb + whi) * 0.5 + 0.1, zr + 0.05), Vector3(0.006, whi - yb - 0.12, 0.012))
			dk.box(Vector3(sx * (hw + 0.004), belt - 0.16, zr - 0.1), Vector3(0.008, 0.07, 0.19))
			tk.box(Vector3(sx * (hw + 0.02), belt - 0.16, zr - 0.1), Vector3(0.02, 0.028, 0.14))
		if not open_back:
			tk.box(Vector3(sx * (hw + 0.07), yb + 0.02, z0 + hood + 0.75), Vector3(0.2, 0.04, 0.7))
		# The mirror: a housing on a short arm at the belt line.
		var mz := z0 + ua + 0.1
		var my := belt + 0.2
		dk.box(Vector3(sx * (hw + 0.09), my - 0.08, mz), Vector3(0.18, 0.04, 0.05))
		dk.box(Vector3(sx * (hw + 0.2), my, mz - 0.01), Vector3(0.09, 0.3, 0.17))
		(g["rim"] as _K).box(Vector3(sx * (hw + 0.2), my, mz + 0.078), Vector3(0.075, 0.26, 0.004))
	# The hood's shut line against the fenders.
	for sx in [-1.0, 1.0]:
		var a3 := Vector3(sx * W * 0.36, gt + 0.004, z0 + 0.09)
		var c3 := Vector3(sx * W * 0.41, ct + 0.006, z0 + hood - 0.02)
		dk.obox((a3 + c3) * 0.5, (c3 - a3) * 0.5, Vector3(0.004, 0, 0), Vector3(0, 0.004, 0))
	# Grille: slats in a surround with a badge, lamps beside it (lens, turn
	# signal), a lower intake in the bumper.
	var gy0 := yb + 0.24
	var gy1 := gt - 0.07
	var gw := W * 0.36
	(g["metal"] as _K).box(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.004), Vector3(gw + 0.05, gy1 - gy0 + 0.05, 0.02))
	dk.box(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.012), Vector3(gw, gy1 - gy0, 0.012))
	for k in 4:
		tk.box(Vector3(0, gy0 + (gy1 - gy0) * (0.14 + 0.24 * float(k)), z0 - 0.02), Vector3(gw, 0.022, 0.008))
	(g["metal"] as _K).cylinder(Vector3(0, (gy0 + gy1) * 0.5, z0 - 0.026), 0.055, 0.012, Vector3.FORWARD, 14)
	var hk: _K = g["head"]
	for sx in [-1.0, 1.0]:
		var hx: float = sx * W * 0.3
		dk.box(Vector3(hx, gt - 0.19, z0 - 0.002), Vector3(0.34, 0.24, 0.05))
		hk.box(Vector3(hx - sx * 0.035, gt - 0.19, z0 - 0.03), Vector3(0.22, 0.19, 0.012))
		(g["amber"] as _K).box(Vector3(hx + sx * 0.125, gt - 0.19, z0 - 0.03), Vector3(0.06, 0.19, 0.012))
	# The high roof over the cab (a full van): a cap lofted from the
	# windshield's header up and back into the body's roof — steep at first,
	# then easing flat, as a Sprinter's or a Transit's high roof does.
	if open_back:
		var H := float(b["h"])
		var bhw := float(b["w"]) * 0.5
		var br := float(b["corner_r"])
		var za := z0 + ws_end - 0.03
		var zb := float(b["z0"]) + float(b["rake_top"]) + 0.55
		if H - ch > 0.08 and zb - za > 0.3:
			var caps: Array = []
			var nst := 9
			for m in nst + 1:
				var t := float(m) / float(nst)
				var e := pow(sin(t * PI * 0.5), 0.75)
				var top := ch - 0.03 + (H - ch + 0.03) * e
				caps.append(_rr_ring(lerpf(hw - 0.01, bhw, minf(t * 2.5, 1.0)), ch - 0.2, top,
					lerpf(0.14, br, e), 0.02, lerpf(za, zb, t)))
			_loft(caps, func(_k, _i): return g["body"], func(_k: int, i: int) -> bool: return i <= 5 or i >= 19, g["body"], false)
		# Amber clearance lamps on the brow of a tall roof.
		if H > 2.6:
			for lx in [-0.5, -0.17, 0.17, 0.5]:
				(g["amber"] as _K).box(Vector3(lx * hw, ch + (H - ch) * 0.62, lerpf(za, zb, 0.2) - 0.01), Vector3(0.08, 0.03, 0.03))


## A cab-over's cab (an Isuzu NPR, a box truck): a flat face, a tall
## windshield raked back to the roof, door glass, lofted like the van's.
static func _cabover_cab(d: Dictionary, g: Dictionary) -> void:
	var cg: Dictionary = d["cab_geo"]
	var z0 := float(cg["z0"])
	var cab_len := float(cg["cab_len"])
	var ch := float(cg["h"])
	var W := float(cg["w"])
	var fy := float(cg["frame_h"])
	var yb := maxf(fy - 0.32, 0.28)
	var belt := fy + 0.78
	var ws_u := 0.3
	var keys := [
		[0.0, W * 0.47, yb + 0.04, belt - 0.02, 0.06, 0.05],
		[0.05, W * 0.5, yb, belt + 0.02, 0.1, 0.06],
		[ws_u, W * 0.5, yb, ch - 0.03, 0.14, 0.06],
		[ws_u + 0.14, W * 0.5, yb, ch, 0.12, 0.06],
		[cab_len, W * 0.5, yb, ch, 0.12, 0.06]]
	var f0 := belt + 0.02 - 0.1
	var f1 := ch - 0.03 - 0.14
	var ua := 0.05 + clampf((belt + 0.05 - f0) / maxf(f1 - f0, 0.05), 0.0, 1.0) * (ws_u - 0.05) + 0.03
	var ub := cab_len - 0.3
	var ws0 := 0.08
	var ws1 := ws_u - 0.03
	var fo := -1.0
	var r := 0.0
	var axles: Array = d["axles"]
	if not axles.is_empty() and not (d["wheels"] as Array).is_empty():
		fo = float((axles[0] as Dictionary)["zf"])
		r = float((d["wheels"] as Array)[0]["r"])
	var R := r + ARCH_CLEAR_M
	var us: Array = [ua, ub, ws0, ws1]
	for kd in keys:
		us.append(float(kd[0]))
	if fo > 0.0 and fo + R < cab_len:
		for m in 11:
			us.append(fo + R * cos(PI * float(m) / 10.0))
	us.sort()
	var rings: Array = []
	var ru: Array = []
	var last := -1.0
	for u0 in us:
		var u := clampf(float(u0), 0.0, cab_len)
		if u - last < 0.01:
			continue
		last = u
		var kp := _key_lerp(keys, u)
		var ybot := float(kp[2])
		if fo > 0.0 and fo + R < cab_len and absf(u - fo) < R:
			ybot = maxf(ybot, r + sqrt(R * R - (u - fo) * (u - fo)))
		rings.append(_rr_ring(float(kp[1]), ybot, float(kp[3]), float(kp[4]), float(kp[5]), z0 + u, belt + 0.05))
		ru.append(u)
	var kit_of := func(k: int, i: int) -> _K:
		var a := float(ru[k])
		var c := float(ru[k + 1])
		if (i == RR_TOP_R or i == RR_TOP_L) and a >= ws0 - 1e-4 and c <= ws1 + 1e-4:
			return g["pane"]
		if (i == RR_WIN_R or i == RR_WIN_L) and a >= ua - 1e-4 and c <= ub + 1e-4:
			return g["pane"]
		return g["body"]
	_loft(rings, kit_of, Callable(), g["body"])
	var hw := W * 0.5
	if fo > 0.0 and fo + R < cab_len:
		_well(g["dark"], hw, z0 + fo, r, R, yb, 0.42)
		_arch_lip(g["trim"], hw - 0.004, z0 + fo, r, R, yb)
	var tk: _K = g["trim"]
	var dk: _K = g["dark"]
	for sx in [-1.0, 1.0]:
		var x: float = sx * (hw + 0.003)
		tk.box(Vector3(x, (yb + ch) * 0.5, z0 + ub + 0.05), Vector3(0.006, ch - yb - 0.3, 0.012))
		dk.box(Vector3(x, belt + 0.035, z0 + (ua + ub) * 0.5), Vector3(0.008, 0.024, ub - ua + 0.04))
		tk.box(Vector3(sx * (hw + 0.02), belt - 0.12, z0 + ub - 0.1), Vector3(0.02, 0.028, 0.14))
		tk.box(Vector3(sx * (hw + 0.06), yb + 0.05, z0 + cab_len * 0.5), Vector3(0.16, 0.04, 0.5))
	for sx in [-1.0, 1.0]:
		var w0 := Vector3(sx * hw * 0.45 - 0.28, belt + 0.1, z0 + 0.085)
		var w1 := Vector3(sx * hw * 0.45 + 0.28, belt + 0.16, z0 + 0.1)
		dk.obox((w0 + w1) * 0.5 + Vector3(0, 0, -0.03), (w1 - w0) * 0.5, Vector3(0, 0.006, 0), Vector3(0, 0, 0.008))


## What shows behind the glass: the driver's and passenger's seats, the dash,
## the steering wheel on its column, and (a van) the cab's floor.
static func _cab_interior(d: Dictionary, g: Dictionary) -> void:
	if not bool(d.get("drivable", true)):
		return
	var cg: Dictionary = d["cab_geo"]
	var b: Dictionary = d["body"]
	var style := str(cg["style"])
	var eye: Vector3 = d["driver_seat"]
	if eye == Vector3.ZERO:
		return
	var integral := bool(cg["integral"])
	var sk: _K = g["seat"]
	var dk: _K = g["dark"]
	var z0 := float(cg["z0"])
	var hood := nose_hood(d)
	var W := float(cg["w"])
	var seat_y := eye.y - 0.8
	var van_nose := style == "full_van" or style == "cutaway"
	# Seats: the driver's, and a passenger's beside it (a bus has none).
	var xs: Array = [eye.x]
	if van_nose or style == "tractor" or (style == "forward" and not integral):
		xs.append(-eye.x)
	for x in xs:
		var sx := float(x)
		dk.box(Vector3(sx, seat_y - 0.2, eye.z + 0.02), Vector3(0.36, 0.3, 0.36))
		sk.box(Vector3(sx, seat_y, eye.z - 0.02), Vector3(0.48, 0.12, 0.5))
		sk.obox(Vector3(sx, seat_y + 0.36, eye.z + 0.27), Vector3(0.23, 0, 0), Vector3(0, 0.33, 0.07), Vector3(0, -0.012, 0.05))
		sk.box(Vector3(sx, seat_y + 0.8, eye.z + 0.345), Vector3(0.24, 0.17, 0.09))
	# The dash across the cab under the windshield.
	var dz := z0 + hood + 0.32
	var dy := float(cg["frame_h"]) + 0.62
	var dw := W - 0.1
	if not van_nose:
		dz = (float(b["z0"]) if integral else z0 + hood) + 0.3
		dy = eye.y - 0.5
		if integral:
			dw = float(b["w"]) - 0.2
	dk.box(Vector3(0, dy - 0.14, dz), Vector3(dw, 0.3, 0.4))
	dk.box(Vector3(eye.x, dy + 0.04, dz + 0.02), Vector3(0.42, 0.1, 0.3))
	# The wheel, tilted on its column.
	var wc := Vector3(eye.x, eye.y - 0.4, eye.z - 0.42)
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(-62.0 if van_nose else -38.0))
	var axis: Vector3 = tilt * Vector3.UP
	var e1: Vector3 = Vector3.RIGHT
	var e2: Vector3 = axis.cross(e1).normalized()
	var seg := 14
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var p0: Vector3 = wc + (e1 * cos(a0) + e2 * sin(a0)) * 0.19
		var p1: Vector3 = wc + (e1 * cos(a1) + e2 * sin(a1)) * 0.19
		dk.obox((p0 + p1) * 0.5, (p1 - p0) * 0.52, axis * 0.014, (p0 + p1 - wc * 2.0).normalized() * 0.014)
	dk.obox(wc, e1 * 0.18, axis * 0.01, e2 * 0.025)
	var col_end := Vector3(eye.x, dy - 0.05, dz + 0.1)
	dk.obox((wc + col_end) * 0.5, (col_end - wc) * 0.5, Vector3(0.025, 0, 0), (col_end - wc).cross(Vector3.RIGHT).normalized() * 0.025)
	# A full van's cab floor (the room's floor starts behind the seats).
	if style == "full_van" and integral:
		var house: Dictionary = d["house"]
		var fz0 := z0 + hood + 0.15
		var fz1 := float(house["z0"])
		if fz1 - fz0 > 0.1:
			dk.box(Vector3(0, float(b["floor_y"]) - 0.03, (fz0 + fz1) * 0.5), Vector3(W - 0.08, 0.06, fz1 - fz0))


## Linear blend of key sections ([u, …] rows sorted by u) at u.
static func _key_lerp(keys: Array, u: float) -> Array:
	if u <= float(keys[0][0]):
		return keys[0]
	for i in keys.size() - 1:
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if u <= float(b[0]):
			var t := (u - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-5)
			var out: Array = []
			for j in a.size():
				out.append(lerpf(float(a[j]), float(b[j]), t))
			return out
	return keys[keys.size() - 1]


## Edge indices of an _rr_ring: the side above the belt (the door glass) and
## the two halves of the top (the windshield, between the corner radii).
const RR_WIN_R := 6
const RR_TOP_R := 11
const RR_TOP_L := 12
const RR_WIN_L := 17


## A rounded rectangle cross-section at z: half width hw, bottom yb, top yt,
## top corners of radius rt, bottom ones rb. Starts at the bottom middle and
## runs round; the same vertex count whatever the sizes, so rings loft.
static func _rr_ring(hw: float, yb: float, yt: float, rt: float, rb: float, z: float,
		belt: float = NAN) -> PackedVector3Array:
	var lim := maxf(minf(hw, (yt - yb) * 0.5) - 0.002, 0.003)
	rt = clampf(rt, 0.003, lim)
	rb = clampf(rb, 0.003, lim)
	# A vertex up each side at the belt line (the door glass's sill), kept
	# between the corners.
	var side_lo := yb + rb
	var side_hi := yt - rt
	var by := (side_lo + side_hi) * 0.5 if is_nan(belt) else clampf(belt, minf(side_lo + 0.002, side_hi), maxf(side_hi - 0.002, side_lo))
	var nc := 4
	var pts := PackedVector3Array()
	pts.append(Vector3(0, yb, z))
	for m in nc + 1:
		var a := -PI * 0.5 + PI * 0.5 * float(m) / float(nc)
		pts.append(Vector3(hw - rb + cos(a) * rb, yb + rb + sin(a) * rb, z))
	pts.append(Vector3(hw, by, z))
	for m in nc + 1:
		var a := PI * 0.5 * float(m) / float(nc)
		pts.append(Vector3(hw - rt + cos(a) * rt, yt - rt + sin(a) * rt, z))
	pts.append(Vector3(0, yt, z))
	for m in nc + 1:
		var a := PI * 0.5 + PI * 0.5 * float(m) / float(nc)
		pts.append(Vector3(-hw + rt + cos(a) * rt, yt - rt + sin(a) * rt, z))
	pts.append(Vector3(-hw, by, z))
	for m in nc + 1:
		var a := PI + PI * 0.5 * float(m) / float(nc)
		pts.append(Vector3(-hw + rb + cos(a) * rb, yb + rb + sin(a) * rb, z))
	return pts


## A wheel well behind an arch cut in a side at |x| = hw: the arc of radius
## R round (zc, yc) above `y_cut`, lined in dark `depth` inward, its back
## closed — so the opening reads as a well round the tyre, not a hole.
static func _well(dk: _K, hw: float, zc: float, yc: float, R: float, y_cut: float, depth: float) -> void:
	var arc := _arch_arc(zc, yc, R, y_cut)
	if arc.size() < 2:
		return
	for sx in [-1.0, 1.0]:
		var x: float = sx * hw
		var xi: float = sx * (hw - depth)
		for m in arc.size() - 1:
			var p := arc[m]
			var q := arc[m + 1]
			var mid := (p + q) * 0.5
			var inward := Vector3(0, yc - mid.y, zc - mid.x).normalized()
			dk.quad(Vector3(x, p.y, p.x), Vector3(x, q.y, q.x), Vector3(xi, q.y, q.x), Vector3(xi, p.y, p.x), inward)
			dk.tri(Vector3(xi, y_cut, zc), Vector3(xi, p.y, p.x), Vector3(xi, q.y, q.x), Vector3(sx, 0, 0))


## The arch's edge in (z, y), front to rear over the top, from where the
## circle meets y_cut on one side to the other. [] when the cut is above it.
static func _arch_arc(zc: float, yc: float, R: float, y_cut: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if y_cut >= yc + R - 0.01:
		return out
	var s := clampf((y_cut - yc) / R, -1.0, 1.0)
	var t0 := PI - asin(s)
	var t1 := asin(s)
	var steps := 14
	for m in steps + 1:
		var t := lerpf(t0, t1, float(m) / float(steps))
		out.append(Vector2(zc + R * cos(t), yc + R * sin(t)))
	return out


## A surface lofted through `rings` (closed loops of one vertex count; ring k
## joined to ring k + 1 by quads). Each face turns away from the line through
## the rings' centres (Godot's front face is clockwise); a vertex's normal is
## the mean of the faces round it that bend less than ~53° from the face being
## drawn, so a crease stays crisp. `kit_of(k, i)` picks the surface for edge i
## between rings k and k + 1,
## `skip(k, i)` leaves a quad out, and `cap` (null = open) closes the first
## and last rings with a fan.
static func _loft(rings: Array, kit_of: Callable, skip: Callable = Callable(), cap: _K = null,
		cap_last: bool = true) -> void:
	var nk := rings.size()
	if nk < 2:
		return
	var n := (rings[0] as PackedVector3Array).size()
	var cen: Array = []
	for rr in rings:
		var c := Vector3.ZERO
		for p in (rr as PackedVector3Array):
			c += p
		cen.append(c / float(maxi(n, 1)))
	var fn: Array = []
	for k in nk - 1:
		var row: Array = []
		var ra: PackedVector3Array = rings[k]
		var rb: PackedVector3Array = rings[k + 1]
		var axis_c: Vector3 = (cen[k] + cen[k + 1]) * 0.5
		for i in n:
			var j := (i + 1) % n
			var nn := (rb[j] - ra[i]).cross(rb[i] - ra[j])
			if nn.length_squared() < 1e-14:
				row.append(Vector3.ZERO)
				continue
			nn = nn.normalized()
			var fc := (ra[i] + ra[j] + rb[j] + rb[i]) * 0.25
			if nn.dot(fc - axis_c) < 0.0:
				nn = -nn
			row.append(nn)
		fn.append(row)
	for k in nk - 1:
		var ra: PackedVector3Array = rings[k]
		var rb: PackedVector3Array = rings[k + 1]
		for i in n:
			if skip.is_valid() and bool(skip.call(k, i)):
				continue
			var f0: Vector3 = fn[k][i]
			if f0 == Vector3.ZERO:
				continue
			var j := (i + 1) % n
			var kk: _K = kit_of.call(k, i)
			kk.quad_n(ra[i], ra[j], rb[j], rb[i], _loft_n(fn, nk, n, k, i, f0), _loft_n(fn, nk, n, k, j, f0),
				_loft_n(fn, nk, n, k + 1, j, f0), _loft_n(fn, nk, n, k + 1, i, f0), f0)
	if cap == null:
		return
	for e in [[0, 1], [nk - 1, nk - 2]]:
		if int(e[0]) != 0 and not cap_last:
			continue
		var rr: PackedVector3Array = rings[int(e[0])]
		var c: Vector3 = cen[int(e[0])]
		var away: Vector3 = (cen[int(e[0])] - cen[int(e[1])]).normalized()
		for i in n:
			var a := rr[i]
			var b := rr[(i + 1) % n]
			var nn := (a - c).cross(b - c)
			if nn.length_squared() < 1e-14:
				continue
			nn = nn.normalized()
			if nn.dot(away) < 0.0:
				nn = -nn
			cap.tri(c, a, b, nn)


## A loft vertex's normal: the faces round vertex (vk, vi) that bend less
## than ~53° from f0, averaged.
static func _loft_n(fn: Array, nk: int, n: int, vk: int, vi: int, f0: Vector3) -> Vector3:
	var sum := Vector3.ZERO
	for qk in [vk - 1, vk]:
		if qk < 0 or qk > nk - 2:
			continue
		for qi in [(vi - 1 + n) % n, vi]:
			var f: Vector3 = fn[qk][qi]
			if f.dot(f0) > 0.6:
				sum += f
	return sum.normalized() if sum.length_squared() > 1e-10 else f0


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

## A door leaf's thickness, and the shut line round it.
const LEAF_T := 0.045
const DOOR_GAP := 0.007
## The narrowest doorway the walk-in collision leaves (the player's capsule
## is 0.7 m across); a narrower drawn door gets this much room all the same.
const WALK_GAP_M := 0.9
## Standing room the collision roof always leaves over the floor.
const WALK_HEAD_M := 1.86


## The arches cut in the body's side panels: VehicleDesign.side_arches for a
## skirted body, and for any other body the same arch over each axle whose
## tyre stands above the panel's bottom edge (a van's rear wheels, a step
## van's fronts).
static func body_arches(d: Dictionary) -> Array:
	var b: Dictionary = d["body"]
	if bool(b.get("skirt", false)):
		return VehicleDesign.side_arches(d)
	var out: Array = []
	var half := float(d["half_len"])
	var y0 := float(b["y0"])
	var z0 := float(b["z0"]) + float(b.get("rake_top", 0.0))
	var z1 := float(b["z1"])
	var r := 0.0
	for w in d["wheels"]:
		r = maxf(r, float((w as Dictionary)["r"]))
	if r <= 0.0:
		return out
	var ra := r + ARCH_CLEAR_M
	for a in d["axles"]:
		var z := float((a as Dictionary)["zf"]) - half
		if z - ra < z0 + 0.04 or z + ra > z1 - 0.04 or r + ra <= y0 + 0.1:
			continue
		out.append({"z": z, "r": ra, "top": r + ra})
	return out


## `outline` minus rectangular `holes` (Rect2) and minus `notches` (polygons
## that reach the outline's edge), as simple polygons with no holes: the
## outline is cut into strips at every hole's left and right edge, so a hole
## always spans the strip it is in and only ever notches it.
static func _cut_panel(outline: PackedVector2Array, holes: Array, notches: Array = []) -> Array:
	var lo := INF
	var hi := -INF
	for p in outline:
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	var cuts: Array = [lo - 1.0]
	var xs: Array = []
	for h in holes:
		var hr: Rect2 = h
		xs.append(hr.position.x)
		xs.append(hr.end.x)
	xs.sort()
	for x in xs:
		if float(x) > lo + 1e-4 and float(x) < hi - 1e-4 and float(x) - float(cuts[cuts.size() - 1]) > 1e-4:
			cuts.append(float(x))
	cuts.append(hi + 1.0)
	var out: Array = []
	for i in cuts.size() - 1:
		var a := float(cuts[i])
		var c := float(cuts[i + 1])
		var strip := PackedVector2Array([Vector2(a, -1000.0), Vector2(c, -1000.0), Vector2(c, 1000.0), Vector2(a, 1000.0)])
		var pieces: Array = Geometry2D.intersect_polygons(outline, strip)
		for h in holes:
			var hr: Rect2 = h
			if hr.position.x >= c - 1e-4 or hr.end.x <= a + 1e-4:
				continue
			var hp := PackedVector2Array([Vector2(a - 0.5, hr.position.y), Vector2(c + 0.5, hr.position.y),
				Vector2(c + 0.5, hr.end.y), Vector2(a - 0.5, hr.end.y)])
			var next: Array = []
			for pc in pieces:
				next.append_array(Geometry2D.clip_polygons(pc, hp))
			pieces = next
		for nt in notches:
			var next2: Array = []
			for pc in pieces:
				next2.append_array(Geometry2D.clip_polygons(pc, nt))
			pieces = next2
		for pc in pieces:
			if absf(_signed_area(pc)) > 1e-5:
				out.append(pc)
	return out


## Polygons (2D) drawn through `map` (2D point -> 3D) facing `n`.
static func _emit_polys(k: _K, polys: Array, map: Callable, n: Vector3) -> void:
	for pg0 in polys:
		var pg: PackedVector2Array = pg0
		var idx := Geometry2D.triangulate_polygon(pg)
		for m in range(0, idx.size(), 3):
			var a: Vector3 = map.call(pg[idx[m]])
			var b: Vector3 = map.call(pg[idx[m + 1]])
			var c: Vector3 = map.call(pg[idx[m + 2]])
			k.tri(a, b, c, n)


static func _rect_poly(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])


## The four faces lining a rectangular opening through a side wall (between
## the skin at |x| = hw and the liner at |x| = hwi), facing into the opening.
static func _side_jamb(k: _K, sx: float, hw: float, hwi: float, r: Rect2) -> void:
	var xo := sx * hw
	var xi := sx * hwi
	var za := r.position.x
	var zb := r.end.x
	var ya := r.position.y
	var yb := r.end.y
	k.quad(Vector3(xo, ya, za), Vector3(xo, ya, zb), Vector3(xi, ya, zb), Vector3(xi, ya, za), Vector3.UP)
	k.quad(Vector3(xo, yb, za), Vector3(xo, yb, zb), Vector3(xi, yb, zb), Vector3(xi, yb, za), Vector3.DOWN)
	k.quad(Vector3(xo, ya, za), Vector3(xi, ya, za), Vector3(xi, yb, za), Vector3(xo, yb, za), Vector3.BACK)
	k.quad(Vector3(xo, ya, zb), Vector3(xi, ya, zb), Vector3(xi, yb, zb), Vector3(xo, yb, zb), Vector3.FORWARD)


## The same for an opening through an end wall (skin at z = zo, liner at zi).
static func _end_jamb(k: _K, zo: float, zi: float, r: Rect2) -> void:
	var xa := r.position.x
	var xb := r.end.x
	var ya := r.position.y
	var yb := r.end.y
	k.quad(Vector3(xa, ya, zo), Vector3(xb, ya, zo), Vector3(xb, ya, zi), Vector3(xa, ya, zi), Vector3.UP)
	k.quad(Vector3(xa, yb, zo), Vector3(xb, yb, zo), Vector3(xb, yb, zi), Vector3(xa, yb, zi), Vector3.DOWN)
	k.quad(Vector3(xa, ya, zo), Vector3(xa, ya, zi), Vector3(xa, yb, zi), Vector3(xa, yb, zo), Vector3.RIGHT)
	k.quad(Vector3(xb, ya, zo), Vector3(xb, ya, zi), Vector3(xb, yb, zi), Vector3(xb, yb, zo), Vector3.LEFT)


## A rubber gasket round a side opening, standing a little proud of the skin.
static func _side_gasket(k: _K, sx: float, hw: float, r: Rect2, t: float = 0.028) -> void:
	var x := sx * (hw + 0.004)
	var zc := r.position.x + r.size.x * 0.5
	var yc := r.position.y + r.size.y * 0.5
	for yy in [r.position.y, r.end.y]:
		k.box(Vector3(x, yy, zc), Vector3(0.012, t, r.size.x + t))
	for zz in [r.position.x, r.end.x]:
		k.box(Vector3(x, yc, zz), Vector3(0.012, r.size.y + t, t))


## The body shell: a rounded cross-section swept along the box, its front
## raked where the vehicle's front is, with REAL openings: the side walls and
## both ends are cut round every window, door and wheel arch (so the glass is
## see-through and the doors — separate leaves, `_door_leaves` — open onto an
## interior the player can walk into), and an inner liner faces the room.
static func _body(d: Dictionary, sh: Dictionary, g: Dictionary) -> void:
	var b: Dictionary = d["body"]
	var cg: Dictionary = d["cab_geo"]
	var house: Dictionary = d["house"]
	var style := str(cg["style"])
	var integral := bool(d["integral"])
	var hw := float(b["w"]) * 0.5
	var hwi := float(house["w"]) * 0.5
	var H := float(b["h"])
	var floor_y := float(b["floor_y"])
	var ceil_y := float(house["ceil_y"])
	var roof := str(b["roof"])
	var r := float(b["corner_r"])
	var crown := float(b["crown"])
	var y0 := float(b["y0"])
	var z0 := float(b["z0"])
	var z1 := float(b["z1"])
	var rake_top := float(b["rake_top"])
	var rake_from := float(b["rake_from"])
	var bk: _K = sh["body"]
	var rk: _K = sh["roof"]
	var tk: _K = sh["trim"]
	var dk: _K = sh["dark"]
	var lk: _K = sh["liner"]
	var pk: _K = sh["pane"]
	var er := float(b.get("end_r", 0.0))
	var arches := body_arches(d)
	var prof := _profile(hw, y0, H, r, crown)
	var yw := H - crown - r
	var roof_y := yw - 0.01
	var n := prof.size()
	var front_round := er > 0.0 and rake_top <= 0.0
	var droop_from := yw - 0.25
	var van := style == "full_van" and integral
	# Stations along the box: [z, inset, drop] (see the rounded ends).
	var st: Array = []
	var seg := 6
	if front_round:
		for j in range(seg, -1, -1):
			var a := PI * 0.5 * float(j) / float(seg)
			st.append([z0 + er - er * sin(a), er * (1.0 - cos(a)), er * 0.6 * (1.0 - cos(a))])
	else:
		st.append([z0, 0.0, 0.0])
	var kf := st.size() - 1
	if er > 0.0:
		for j in seg + 1:
			var a := PI * 0.5 * float(j) / float(seg)
			st.append([z1 - er + er * sin(a), er * (1.0 - cos(a)), er * 0.6 * (1.0 - cos(a))])
	else:
		st.append([z1, 0.0, 0.0])
	var rings: Array = []
	for k in st.size():
		var sz := float(st[k][0])
		var sxs := (hw - float(st[k][1])) / hw
		var drop := float(st[k][2])
		var ring := PackedVector3Array()
		for p in prof:
			var y := p.y - drop * clampf((p.y - droop_from) / maxf(H - droop_from, 0.01), 0.0, 1.0)
			var z := sz + (_rake(p.y, rake_from, H, rake_top) if k == 0 and not front_round else 0.0)
			ring.append(Vector3(p.x * sxs, y, z))
		rings.append(ring)
	var paint_d: Dictionary = (d["spec"] as Dictionary)["paint"]
	var plain_front := str(paint_d.get("livery", "")) == "transit" and str(paint_d.get("wrap", "")).is_empty()
	var kit_of := func(k: int, i: int) -> _K:
		if plain_front and front_round and k < kf:
			return rk
		return rk if prof[i].y >= roof_y and prof[(i + 1) % n].y >= roof_y else bk
	# The flat stretch's side walls are drawn below, cut round their openings.
	var skip := func(k: int, i: int) -> bool:
		if k != kf:
			return false
		if i == 0:
			return true   # the underside, drawn below round the wheel wells
		var p := prof[i]
		var q := prof[(i + 1) % n]
		return p.x * q.x > 0.0 and absf(absf(p.x) - hw) < 1e-4 and absf(absf(q.x) - hw) < 1e-4 \
			and p.y <= yw + 1e-4 and q.y <= yw + 1e-4
	_loft(rings, kit_of, skip)
	var za := float(st[kf][0])
	var zb := float(st[kf + 1][0])
	var zr := float(st[st.size() - 1][0])
	var spans := VehicleDesign.door_spans(d)
	var wins := VehicleDesign.window_spans(d)
	var wkind := str(b["windows"])
	# Where the room's liner starts: an integral body (a bus, a step van, a
	# Class A) is one room from the windshield back; a van's cab is its own.
	var lz0 := float(house["z0"])
	if integral and not van:
		lz0 = z0 + rake_top + 0.05
	var lz1 := float(house["z1"])
	# --- side walls -----------------------------------------------------------
	var outline := PackedVector2Array([Vector2(za, y0), Vector2(zb, y0), Vector2(zb, yw)])
	var rk_top := _rake(yw, rake_from, H, rake_top) if not front_round else 0.0
	outline.append(Vector2(za + rk_top, yw))
	if rk_top > 0.0 and rake_from > y0 + 0.01 and rake_from < yw - 0.01:
		outline.append(Vector2(za, rake_from))
	var notches: Array = []
	for a0 in arches:
		var ad: Dictionary = a0
		var zc := float(ad["z"])
		var R := float(ad["r"])
		var yc := float(ad["top"]) - R
		var arc := _arch_arc(zc, yc, R, y0 - 0.05)
		if arc.size() < 2:
			continue
		arc.append(Vector2(arc[arc.size() - 1].x, y0 - 0.6))
		arc.append(Vector2(arc[0].x, y0 - 0.6))
		notches.append(arc)
		_well(dk, hw, zc, yc, R, y0, ARCH_DEPTH if bool(b.get("skirt", false)) else 0.5)
		_arch_lip(tk, hw, zc, yc, R, y0)
	# The underside, open over each wheel well.
	var well_d := ARCH_DEPTH if bool(b.get("skirt", false)) else 0.5
	var wells: Array = []
	for a1 in arches:
		var ad1: Dictionary = a1
		for sx in [-1.0, 1.0]:
			wells.append(Rect2(float(ad1["z"]) - float(ad1["r"]), (hw - well_d) if sx > 0.0 else -hw - 0.1,
				float(ad1["r"]) * 2.0, well_d + 0.1))
	_emit_polys(bk, _cut_panel(_rect_poly(za, -hw, zb, hw), wells), func(p: Vector2) -> Vector3: return Vector3(p.y, y0, p.x), Vector3.DOWN)
	# A full van's cab doors reach back into the body: their glass (behind
	# the pillar where the body starts) and shut lines are on these walls.
	var cab_wins: Array = []
	if van:
		var eye: Vector3 = d["driver_seat"]
		var cfy := float(cg["frame_h"])
		var cw0 := z0 + 0.07
		var cw1 := minf(eye.z + 0.38, float(house["z0"]) - 0.3)
		var cy0 := cfy + 0.92
		var cy1 := float(cg["h"]) - 0.17
		if cw1 - cw0 > 0.2 and cy1 - cy0 > 0.2:
			cab_wins.append(Rect2(cw0, cy0, cw1 - cw0, cy1 - cy0))
			for sx in [-1.0, 1.0]:
				var cx: float = sx * (hw + 0.003)
				tk.box(Vector3(cx, (y0 + cy1) * 0.5 + 0.1, cw1 + 0.07), Vector3(0.006, cy1 - y0 - 0.12, 0.012))
				dk.box(Vector3(cx, cy0 - 0.012, (cw0 + cw1) * 0.5), Vector3(0.008, 0.024, cw1 - cw0 + 0.06))
				dk.box(Vector3(sx * (hw + 0.004), cy0 - 0.16, cw1 - 0.06), Vector3(0.008, 0.07, 0.19))
				tk.box(Vector3(sx * (hw + 0.02), cy0 - 0.16, cw1 - 0.06), Vector3(0.02, 0.028, 0.14))
	var liner_rect := _rect_poly(lz0, floor_y, lz1, ceil_y)
	for sx in [-1.0, 1.0]:
		var holes: Array = []
		var win_rects: Array = []
		for cwr in cab_wins:
			holes.append(cwr)
			win_rects.append(cwr)
		for w in wins:
			var wd: Dictionary = w
			if float(wd["sx"]) != sx:
				continue
			var wr := Rect2(float(wd["z0"]), float(wd["y0"]), float(wd["z1"]) - float(wd["z0"]), float(wd["y1"]) - float(wd["y0"]))
			holes.append(wr)
			win_rects.append(wr)
		var door_rects: Array = []
		if sx > 0.0:
			for sp in spans:
				var sd: Dictionary = sp
				if str(sd["where"]) != "side":
					continue
				var dr := Rect2(float(sd["z0"]), float(sd["y0"]), float(sd["z1"]) - float(sd["z0"]), float(sd["y1"]) - float(sd["y0"]))
				holes.append(dr)
				door_rects.append(dr)
		var x: float = sx * hw
		var xi: float = sx * hwi
		_emit_polys(bk, _cut_panel(outline, holes, notches), func(p: Vector2) -> Vector3: return Vector3(x, p.y, p.x), Vector3(sx, 0, 0))
		_emit_polys(lk, _cut_panel(liner_rect, holes), func(p: Vector2) -> Vector3: return Vector3(xi, p.y, p.x), Vector3(-sx, 0, 0))
		for wr0 in win_rects:
			var wr: Rect2 = wr0
			_side_jamb(tk, sx, hw, hwi, wr)
			_side_gasket(tk, sx, hw, wr)
			var gx: float = sx * (hw - 0.012)
			pk.quad(Vector3(gx, wr.position.y, wr.position.x), Vector3(gx, wr.position.y, wr.end.x),
				Vector3(gx, wr.end.y, wr.end.x), Vector3(gx, wr.end.y, wr.position.x), Vector3(sx, 0, 0))
			if wkind == "bus":
				# A school bus's split sash: the bar across the middle.
				tk.box(Vector3(sx * (hw - 0.006), wr.position.y + wr.size.y * 0.52, wr.position.x + wr.size.x * 0.5),
					Vector3(0.02, 0.03, wr.size.x))
		for dr0 in door_rects:
			var dr: Rect2 = dr0
			_side_jamb(dk, sx, hw, hwi, dr)
			# The kick panel under the floor behind a door that reaches below it.
			if dr.position.y < floor_y - 0.06:
				var kx := hw - LEAF_T - 0.02
				dk.quad(Vector3(kx, dr.position.y, dr.position.x), Vector3(kx, dr.position.y, dr.end.x),
					Vector3(kx, floor_y, dr.end.x), Vector3(kx, floor_y, dr.position.x), Vector3.RIGHT)
		if wkind == "band":
			# A transit band: each run of panes set in one dark surround.
			var side: Array = win_rects.duplicate()
			side.sort_custom(func(a, c): return (a as Rect2).position.x < (c as Rect2).position.x)
			var run: Array = []
			for wr1 in side + [null]:
				if not run.is_empty() and (wr1 == null or (wr1 as Rect2).position.x - float(run[1]) > 0.25):
					var sur := _rect_poly(float(run[0]) - 0.05, float(run[2]) - 0.05, float(run[1]) + 0.05, float(run[3]) + 0.05)
					var sxx: float = sx * (hw + 0.002)
					_emit_polys(tk, _cut_panel(sur, win_rects), func(p: Vector2) -> Vector3: return Vector3(sxx, p.y, p.x), Vector3(sx, 0, 0))
					run = []
				if wr1 == null:
					break
				var w2: Rect2 = wr1
				if run.is_empty():
					run = [w2.position.x, w2.end.x, w2.position.y, w2.end.y]
				else:
					run[1] = w2.end.x
	# --- the rear ---------------------------------------------------------------
	var rear := str(b["rear_door"])
	var rear_holes: Array = []
	var rear_win := Rect2()
	for sp in spans:
		var sd: Dictionary = sp
		if str(sd["where"]) == "rear":
			rear_holes.append(Rect2(float(sd["x0"]), float(sd["y0"]), float(sd["x1"]) - float(sd["x0"]), float(sd["y1"]) - float(sd["y0"])))
	if rear_holes.is_empty() and (wkind == "bus" or wkind == "band"):
		var y_lo := floor_y + 0.95
		var y_hi := minf(yw - 0.18, floor_y + 1.75)
		if y_hi - y_lo > 0.25:
			rear_win = Rect2(-(hw - er) * 0.72, y_lo, (hw - er) * 1.44, y_hi - y_lo)
			rear_holes.append(rear_win)
	var br: PackedVector3Array = rings[rings.size() - 1]
	var rear_poly := PackedVector2Array()
	for p3 in br:
		rear_poly.append(Vector2(p3.x, p3.y))
	_emit_polys(bk, _cut_panel(rear_poly, rear_holes), func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, zr), Vector3.BACK)
	_emit_polys(lk, _cut_panel(_rect_poly(-hwi, floor_y, hwi, ceil_y), rear_holes),
		func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, lz1), Vector3.FORWARD)
	for rh in rear_holes:
		_end_jamb(dk, zr, lz1, rh)
	if rear_win.size.x > 0.0:
		pk.quad(Vector3(rear_win.position.x, rear_win.position.y, zr - 0.012), Vector3(rear_win.end.x, rear_win.position.y, zr - 0.012),
			Vector3(rear_win.end.x, rear_win.end.y, zr - 0.012), Vector3(rear_win.position.x, rear_win.end.y, zr - 0.012), Vector3.BACK)
		for yy in [rear_win.position.y, rear_win.end.y]:
			tk.box(Vector3(0, yy, zr + 0.004), Vector3(rear_win.size.x + 0.03, 0.03, 0.012))
		for xx in [rear_win.position.x, rear_win.end.x]:
			tk.box(Vector3(xx, rear_win.position.y + rear_win.size.y * 0.5, zr + 0.004), Vector3(0.03, rear_win.size.y + 0.03, 0.012))
	# --- the front --------------------------------------------------------------
	var fr: PackedVector3Array = rings[0]
	var zf := float(st[0][0])
	if van:
		pass   # the cab's loft and the high roof's fairing close it (_cab_loft)
	elif integral:
		# The windshield is an opening in the body's own front face: a Class
		# A's from ~0.9 m over the body's bottom edge, a bus's from above the
		# hood line; two panes with a post between them.
		var ws_lo := y0 + 0.9 if style == "forward" else floor_y + 0.85
		var ws_hi := minf(yw - 0.2, ws_lo + 1.3)
		var ws := Rect2(-hw * 0.9, ws_lo, hw * 1.8, ws_hi - ws_lo)
		var front_poly := PackedVector2Array()
		for p3 in fr:
			front_poly.append(Vector2(p3.x, p3.y))
		var slope := rake_top / maxf(H - rake_from, 0.01) if rake_top > 0.0 else 0.0
		var fmap := func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, zf + _rake(p.y, rake_from, H, rake_top))
		var parts: Array = [[front_poly, Vector3.FORWARD]]
		if rake_top > 0.0:
			parts = [[Geometry2D.intersect_polygons(front_poly, _rect_poly(-50.0, -50.0, 50.0, rake_from)), Vector3.FORWARD],
				[Geometry2D.intersect_polygons(front_poly, _rect_poly(-50.0, rake_from, 50.0, 50.0)), Vector3(0, slope, -1).normalized()]]
		for part in parts:
			var polys: Array = part[0] if part[0] is Array else [part[0]]
			for pg in polys:
				_emit_polys(bk, _cut_panel(pg, [ws]), fmap, part[1])
		var off := Vector3(0, 0, 0.012)
		for half_x in [[ws.position.x, -0.03], [0.03, ws.end.x]]:
			var xa := float(half_x[0])
			var xb := float(half_x[1])
			pk.quad(fmap.call(Vector2(xa, ws_lo)) + off, fmap.call(Vector2(xb, ws_lo)) + off,
				fmap.call(Vector2(xb, ws_hi)) + off, fmap.call(Vector2(xa, ws_hi)) + off, Vector3.FORWARD)
		# The centre post, the gasket and two wipers.
		var pm: Vector3 = (fmap.call(Vector2(0, ws_lo)) + fmap.call(Vector2(0, ws_hi))) * 0.5
		var up: Vector3 = (fmap.call(Vector2(0, ws_hi)) - fmap.call(Vector2(0, ws_lo)))
		tk.obox(pm, Vector3(0.03, 0, 0), up * 0.5, Vector3(0, 0, 0.012))
		for yy in [ws_lo, ws_hi]:
			var c: Vector3 = fmap.call(Vector2(0, yy))
			tk.box(c - Vector3(0, 0, 0.004), Vector3(ws.size.x + 0.04, 0.035, 0.014))
		for xx in [ws.position.x, ws.end.x]:
			var c2: Vector3 = (fmap.call(Vector2(xx, ws_lo)) + fmap.call(Vector2(xx, ws_hi))) * 0.5
			tk.obox(c2 - Vector3(0, 0, 0.004), Vector3(0.018, 0, 0), up * 0.5, Vector3(0, 0, 0.007))
		for sx in [-1.0, 1.0]:
			var w0: Vector3 = fmap.call(Vector2(sx * hw * 0.42, ws_lo + 0.02)) - Vector3(0, 0, 0.02)
			var w1: Vector3 = fmap.call(Vector2(sx * hw * 0.42 - 0.45, ws_lo + 0.3)) - Vector3(0, 0, 0.02)
			dk.obox((w0 + w1) * 0.5, (w1 - w0) * 0.5, Vector3(0, 0.008, 0), Vector3(0, 0, 0.008))
	else:
		var fpoly := PackedVector2Array()
		for p3 in fr:
			fpoly.append(Vector2(p3.x, p3.y))
		var rk2 := rake_top if not front_round else 0.0
		var fmap2 := func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, zf + _rake(p.y, rake_from, H, rk2))
		if rk2 > 0.0:
			_emit_polys(bk, Geometry2D.intersect_polygons(fpoly, _rect_poly(-50.0, -50.0, 50.0, rake_from)), fmap2, Vector3.FORWARD)
			_emit_polys(bk, Geometry2D.intersect_polygons(fpoly, _rect_poly(-50.0, rake_from, 50.0, 50.0)), fmap2,
				Vector3(0, rk2 / maxf(H - rake_from, 0.01), -1).normalized())
		else:
			_emit_polys(bk, [fpoly], fmap2, Vector3.FORWARD)
		# The bulkhead's room side.
		lk.quad(Vector3(-hwi, floor_y, lz0), Vector3(hwi, floor_y, lz0), Vector3(hwi, ceil_y, lz0),
			Vector3(-hwi, ceil_y, lz0), Vector3.BACK)
	# The headliner.
	lk.quad(Vector3(-hwi, ceil_y, lz0), Vector3(hwi, ceil_y, lz0), Vector3(hwi, ceil_y, lz1),
		Vector3(-hwi, ceil_y, lz1), Vector3.DOWN)
	# Clearance lamps on a bus body: red across the rear's top, amber on
	# the front cap (VehicleBuilder._front_cap).
	if bool(b.get("skirt", false)):
		var ly := yw - 0.1
		for lx in [-0.18, 0.0, 0.18, -(hw - er - 0.12), hw - er - 0.12]:
			(g["tail"] as _K).box(Vector3(lx, ly, z1 + 0.012), Vector3(0.07, 0.035, 0.02))
	if bool(b.get("front_cap", false)):
		_front_cap(d, sh)
	# The Class C's bunk over the cab.
	if roof == "cabover":
		_cabover(d, sh)
	_door_trim(d, sh, hw, floor_y, y0)
	_body_details(d, sh, hw, y0, yw, za, zb, zr, er, front_round)
	# Stripe band down both sides.
	var paint: Dictionary = (d["spec"] as Dictionary)["paint"]
	if bool(paint.get("stripe_on", false)):
		var sk: _K = sh["stripe"]
		var sy0 := floor_y + 0.18
		var sy1 := sy0 + 0.16
		var stripe := _rect_poly(z0 + 0.05 + (er if front_round else 0.0) + rk_top * 0.3, sy0, z1 - 0.05 - er, sy1)
		for sx in [-1.0, 1.0]:
			var x2: float = sx * (hw + 0.003)
			var cuts: Array = []
			if sx > 0.0:
				for sp in spans:
					if str((sp as Dictionary)["where"]) == "side":
						cuts.append(Rect2(float(sp["z0"]), float(sp["y0"]), float(sp["z1"]) - float(sp["z0"]), float(sp["y1"]) - float(sp["y0"])))
			_emit_polys(sk, _cut_panel(stripe, cuts), func(p: Vector2) -> Vector3: return Vector3(x2, p.y, p.x), Vector3(sx, 0, 0))


## The moulding round a wheel arch: a lip following the cut, a hand proud of
## the panel.
static func _arch_lip(tk: _K, hw: float, zc: float, yc: float, R: float, y_cut: float) -> void:
	var arc := _arch_arc(zc, yc, R + 0.015, y_cut)
	for sx in [-1.0, 1.0]:
		for m in arc.size() - 1:
			var p := arc[m]
			var q := arc[m + 1]
			var mid := Vector3(sx * (hw + 0.012), (p.y + q.y) * 0.5, (p.x + q.x) * 0.5)
			var along := Vector3(0, q.y - p.y, q.x - p.x) * 0.5
			var out := Vector3(0, mid.y - yc, mid.z - zc).normalized() * 0.022
			tk.obox(mid, Vector3(0.018, 0, 0), along * 1.04, out)


## The bunk over a Class C's cab: a rounded pod lofted forward from the box.
static func _cabover(d: Dictionary, sh: Dictionary) -> void:
	var b: Dictionary = d["body"]
	var cg: Dictionary = d["cab_geo"]
	var hw := float(b["w"]) * 0.5
	var H := float(b["h"])
	var z0 := float(b["z0"])
	var cy0 := float(cg["h"]) + 0.03
	var cy1 := H - 0.1
	var zn := float(cg["z0"]) + float(cg["hood"]) * 0.45
	var L := z0 - zn
	if L < 0.3 or cy1 - cy0 < 0.3:
		return
	var keys := [
		[-0.2, hw - 0.03, cy0, cy1, 0.16, 0.06],
		[L * 0.55, hw - 0.04, cy0, cy1 - 0.02, 0.18, 0.1],
		[L * 0.85, hw - 0.1, cy0 + (cy1 - cy0) * 0.12, cy1 - 0.1, 0.22, 0.2],
		[L, hw - 0.22, cy0 + (cy1 - cy0) * 0.3, cy1 - 0.32, 0.2, 0.2]]
	var rings: Array = []
	for kd in keys:
		rings.append(_rr_ring(float(kd[1]), float(kd[2]), float(kd[3]), float(kd[4]), float(kd[5]), z0 - float(kd[0])))
	_loft(rings, func(_k, _i): return sh["body"], Callable(), sh["body"])
	# The bunk's front window.
	var k2: Array = keys[2]
	var k3: Array = keys[3]
	var wy0 := float(k3[2]) + 0.06
	var wy1 := float(k3[3]) - 0.06
	if wy1 - wy0 > 0.15:
		(sh["glass"] as _K).box(Vector3(0, (wy0 + wy1) * 0.5, z0 - L - 0.004), Vector3(float(k3[1]) * 1.3, wy1 - wy0, 0.01))
	for lx in [-0.5, -0.17, 0.17, 0.5]:
		(sh["amber"] as _K).box(Vector3(lx * hw, float(k2[3]) + 0.0, z0 - L * 0.86), Vector3(0.09, 0.03, 0.05))


## What stays on the body round its doors: running boards and steps, the
## track of a slider, hinges.
static func _door_trim(d: Dictionary, sh: Dictionary, hw: float, floor_y: float, y0: float) -> void:
	var b: Dictionary = d["body"]
	var tk: _K = sh["trim"]
	var side := str(b["side_door"])
	for sp in VehicleDesign.door_spans(d):
		var sd: Dictionary = sp
		if str(sd["where"]) != "side":
			continue
		var dz0 := float(sd["z0"])
		var dz1 := float(sd["z1"])
		var dy0 := float(sd["y0"])
		var dy1 := float(sd["y1"])
		var kind := str(sd.get("kind", side))
		var zm := (dz0 + dz1) * 0.5
		match kind:
			"slider":
				# The rail the door runs back along, and a step under it.
				tk.box(Vector3(hw + 0.008, floor_y + 0.84, dz1 + (dz1 - dz0) * 0.5 + 0.05), Vector3(0.016, 0.03, dz1 - dz0))
				tk.box(Vector3(hw + 0.1, y0 - 0.06, zm), Vector3(0.22, 0.04, dz1 - dz0 + 0.3))
			"hinged":
				tk.box(Vector3(hw + 0.13, maxf(y0 - 0.06, floor_y - 0.42), zm), Vector3(0.28, 0.04, dz1 - dz0 + 0.2))
				for hy in [dy0 + 0.25, (dy0 + dy1) * 0.5, dy1 - 0.25]:
					tk.box(Vector3(hw + 0.01, hy, dz0 - 0.012), Vector3(0.02, 0.1, 0.03))
			"bus":
				if dy0 > 0.45:
					tk.box(Vector3(hw + 0.14, dy0 - BUS_STEP_M, zm), Vector3(0.3, 0.05, dz1 - dz0 - 0.04))
					tk.box(Vector3(hw + 0.02, dy0 - BUS_STEP_M * 0.5, zm), Vector3(0.03, BUS_STEP_M, dz1 - dz0 - 0.04))


## Body furniture that makes a box read as a vehicle: the rain gutter, roof
## ribs on a bus, rub rails, the rocker trim, marker lamps down the sides,
## the fuel filler, tail lamp clusters, the rear bumper with its step and
## plate, mud flaps and the exhaust tip.
static func _body_details(d: Dictionary, sh: Dictionary, hw: float, y0: float, yw: float,
		za: float, zb: float, zr: float, er: float, front_round: bool) -> void:
	var b: Dictionary = d["body"]
	var tk: _K = sh["trim"]
	var dk: _K = sh["dark"]
	var bk: _K = sh["body"]
	var floor_y := float(b["floor_y"])
	var H := float(b["h"])
	var trailer := str(d["cab"]) == "none"
	var bid := str(b["id"])
	var bus := bid == "skoolie"
	var boxy := float(b["corner_r"]) < 0.06
	# The drip rail where the wall meets the roof.
	if not boxy:
		for sx in [-1.0, 1.0]:
			tk.box(Vector3(sx * (hw + 0.006), yw + 0.012, (za + zb) * 0.5), Vector3(0.018, 0.022, zb - za - 0.04))
	else:
		# A box body's aluminium top and bottom rails and corner posts.
		for sx in [-1.0, 1.0]:
			for yy in [y0 + 0.04, H - 0.05]:
				(sh["metal"] as _K).box(Vector3(sx * (hw + 0.004), yy, (za + zb) * 0.5), Vector3(0.016, 0.09, zb - za))
			for zz in [za + 0.04, zb - 0.04]:
				(sh["metal"] as _K).box(Vector3(sx * (hw + 0.004), (y0 + H) * 0.5, zz), Vector3(0.016, H - y0, 0.09))
	if bus:
		# Roof ribs every window bay, and the rub rails.
		var zz := za + 0.5
		var crown := float(b["crown"])
		var r := float(b["corner_r"])
		while zz < zb - 0.2:
			for sx in [-1.0, 1.0]:
				tk.box(Vector3(sx * (hw + 0.003), yw - 0.02, zz), Vector3(0.008, 0.06, 0.035))
			zz += 0.89
		var _unused := crown + r
		for ry in [floor_y - 0.2, floor_y + 0.25, floor_y + 0.62]:
			for sx in [-1.0, 1.0]:
				var rail := _rect_poly(za + 0.05, ry - 0.035, zb - 0.05, ry + 0.035)
				var cuts: Array = []
				if sx > 0.0:
					for sp in VehicleDesign.door_spans(d):
						if str((sp as Dictionary)["where"]) == "side":
							cuts.append(Rect2(float(sp["z0"]) - 0.03, -10.0, float(sp["z1"]) - float(sp["z0"]) + 0.06, 20.0))
				for a0 in body_arches(d):
					var ad: Dictionary = a0
					if ry < float(ad["top"]) + 0.06:
						cuts.append(Rect2(float(ad["z"]) - float(ad["r"]) - 0.05, -10.0, float(ad["r"]) * 2.0 + 0.1, 20.0))
				for pg0 in _cut_panel(rail, cuts):
					var pg: PackedVector2Array = pg0
					var lo := pg[0].x
					var hi := pg[0].x
					for p in pg:
						lo = minf(lo, p.x)
						hi = maxf(hi, p.x)
					dk.box(Vector3(sx * (hw + 0.012), ry, (lo + hi) * 0.5), Vector3(0.024, 0.07, hi - lo))
	if bus:
		# The eight-way warning lamps and the name boards, front and rear.
		var zfw := float(b["z0"]) - 0.012
		for e in [[zfw, -1.0], [zr + 0.012, 1.0]]:
			var zz2 := float(e[0])
			dk.box(Vector3(0, yw + 0.02, zz2), Vector3(hw * 0.9, 0.2, 0.014))
			for sx in [-1.0, 1.0]:
				(sh["tail"] as _K).cylinder(Vector3(sx * hw * 0.78, yw + 0.02, zz2 + float(e[1]) * 0.01), 0.085, 0.02, Vector3.BACK, 12)
				(sh["amber"] as _K).cylinder(Vector3(sx * hw * 0.58, yw + 0.02, zz2 + float(e[1]) * 0.01), 0.085, 0.02, Vector3.BACK, 12)
	# Side marker lamps (amber ahead, red at the rear) and the fuel filler.
	var my := maxf(y0 + 0.12, floor_y - 0.12)
	for sx in [-1.0, 1.0]:
		(sh["amber"] as _K).box(Vector3(sx * (hw + 0.006), my, za + 0.18), Vector3(0.014, 0.04, 0.09))
		(sh["tail"] as _K).box(Vector3(sx * (hw + 0.006), my, zb - 0.14), Vector3(0.014, 0.04, 0.09))
	if not trailer and str(d["fuel"]) != "electric":
		var fz := zb - (zb - za) * 0.22
		for a0 in body_arches(d):
			if absf(float((a0 as Dictionary)["z"]) - fz) < float((a0 as Dictionary)["r"]) + 0.25:
				fz = float((a0 as Dictionary)["z"]) + float((a0 as Dictionary)["r"]) + 0.3
		if fz < zb - 0.2:
			dk.box(Vector3(-(hw + 0.003), floor_y + 0.32, fz), Vector3(0.008, 0.2, 0.2))
			bk.box(Vector3(-(hw + 0.005), floor_y + 0.32, fz), Vector3(0.008, 0.17, 0.17))
	# Tail lamp clusters: stop, turn, reverse, stacked in a housing.
	var hx := hw - er - 0.17
	var ly := maxf(y0 + 0.42, floor_y - 0.02) if bool(b.get("skirt", false)) else maxf(y0 + 0.42, floor_y + 0.25)
	if bus:
		ly = floor_y + 0.55
	for sx in [-1.0, 1.0]:
		var lx: float = sx * hx
		dk.box(Vector3(lx, ly, zr + 0.02), Vector3(0.17, 0.46, 0.04))
		(sh["tail"] as _K).box(Vector3(lx, ly + 0.13, zr + 0.045), Vector3(0.13, 0.15, 0.012))
		(sh["amber"] as _K).box(Vector3(lx, ly - 0.02, zr + 0.045), Vector3(0.13, 0.11, 0.012))
		(sh["lamp"] as _K).box(Vector3(lx, ly - 0.15, zr + 0.045), Vector3(0.13, 0.09, 0.012))
		# Mud flaps behind the rear wheels.
	# The high-mounted stop lamp.
	if not boxy:
		(sh["tail"] as _K).box(Vector3(0, yw - 0.02, zr + 0.01), Vector3(0.3, 0.03, 0.02))
	# Rear bumper: a step bumper with end caps, the plate lit above it.
	var by := y0 + 0.02 if not boxy else maxf(y0 - 0.3, 0.45)
	tk.box(Vector3(0, by, zr + 0.09), Vector3(hw * 1.94, 0.17, 0.18))
	(sh["metal"] as _K).box(Vector3(0, by + 0.088, zr + 0.09), Vector3(hw * 1.5, 0.006, 0.15))
	for sx in [-1.0, 1.0]:
		dk.box(Vector3(sx * (hw * 0.97 - 0.06), by, zr + 0.095), Vector3(0.12, 0.175, 0.19))
	if boxy:
		for sx in [-1.0, 1.0]:
			tk.box(Vector3(sx * hw * 0.55, (by + y0) * 0.5 + 0.05, zr + 0.02), Vector3(0.07, y0 - by + 0.1, 0.07))
	var plate_x := -hw * 0.45 if str(b["rear_door"]) != "none" else 0.0
	(sh["white"] as _K).box(Vector3(plate_x, by + 0.2 if str(b["rear_door"]) == "none" else by, zr + (0.012 if str(b["rear_door"]) == "none" else 0.182)),
		Vector3(0.31, 0.155, 0.006))
	# Mud flaps and the tailpipe.
	var half := float(d["half_len"])
	var axles: Array = d["axles"]
	var wheels: Array = d["wheels"]
	if not axles.is_empty() and not wheels.is_empty():
		var wr := float((wheels[0] as Dictionary)["r"])
		var zl := float((axles[axles.size() - 1] as Dictionary)["zf"]) - half
		if zl + wr + 0.12 < zr - 0.05:
			for sx in [-1.0, 1.0]:
				dk.box(Vector3(sx * (hw - 0.2), wr * 0.75, zl + wr + 0.1), Vector3(0.3, wr * 1.1, 0.012))
		if not trailer and str(d["fuel"]) != "electric":
			(sh["metal"] as _K).cylinder(Vector3(-hw * 0.6, maxf(y0 - 0.12, 0.3), zr - 0.12), 0.035, 0.45, Vector3.BACK, 10)
	var _fr := front_round


## The door leaves, each its own mesh in VEHICLE coordinates (so a livery
## runs across it and the closed leaf needs no transform): [{name, kits,
## open (the leaf's transform fully open), door (its index in
## VehicleDesign.door_spans), where, kind}].
static func _door_leaves(d: Dictionary) -> Array:
	var out: Array = []
	var b: Dictionary = d["body"]
	var hw := float(b["w"]) * 0.5
	var floor_y := float(b["floor_y"])
	var side := str(b["side_door"])
	var glazed := str(b["windows"]) != "none"
	var spans := VehicleDesign.door_spans(d)
	var zr := float(b["z1"])
	for si in spans.size():
		var sd: Dictionary = spans[si]
		var y0 := float(sd["y0"]) + DOOR_GAP
		var y1 := float(sd["y1"]) - DOOR_GAP
		if str(sd["where"]) == "side":
			var z0 := float(sd["z0"]) + DOOR_GAP
			var z1 := float(sd["z1"]) - DOOR_GAP
			var zm := (z0 + z1) * 0.5
			var kind := str(sd.get("kind", side))
			match kind:
				"bus":
					# Two glass leaves swinging out from the middle.
					for li in 2:
						var a := z0 if li == 0 else zm + DOOR_GAP * 0.5
						var c := zm - DOOR_GAP * 0.5 if li == 0 else z1
						var kits := _leaf_kits()
						_side_leaf(kits, hw, a, c, y0, y1, {"frame": "trim",
							"win": Rect2(a + 0.05, y0 + 0.09, c - a - 0.1, y1 - y0 - 0.17)})
						(kits["metal"] as _K).cylinder(Vector3(hw - LEAF_T - 0.03, floor_y + 1.05, (c - 0.05) if li == 0 else (a + 0.05)),
							0.014, 0.7, Vector3.UP, 6)
						var hinge := Vector3(hw, 0, a if li == 0 else c)
						out.append({"name": "D%d_%d" % [si, li], "kits": kits, "door": si, "where": "side", "kind": kind,
							"open": _swing(hinge, Vector3.UP, deg_to_rad(96.0 if li == 0 else -96.0))})
				"lift":
					var wy1 := y1 - 0.14
					var wy0 := maxf(wy1 - 0.62, floor_y + 0.9)
					for li in 2:
						var a := z0 if li == 0 else zm + DOOR_GAP * 0.5
						var c := zm - DOOR_GAP * 0.5 if li == 0 else z1
						var kits := _leaf_kits()
						var ww := minf(0.32, c - a - 0.18) * 0.5
						var mc := (a + c) * 0.5
						_side_leaf(kits, hw, a, c, y0, y1, {"win": Rect2(mc - ww, wy0, ww * 2.0, wy1 - wy0) if ww > 0.06 else Rect2(),
							"handle_z": (c - 0.1) if li == 0 else (a + 0.1), "handle_y": floor_y + 1.0})
						var hinge := Vector3(hw, 0, a if li == 0 else c)
						out.append({"name": "D%d_%d" % [si, li], "kits": kits, "door": si, "where": "side", "kind": kind,
							"open": _swing(hinge, Vector3.UP, deg_to_rad(105.0 if li == 0 else -105.0))})
				"slider", "sliding_step":
					var kits := _leaf_kits()
					var win := Rect2()
					if glazed and kind == "slider":
						win = Rect2(z0 + 0.14, floor_y + 0.98, z1 - z0 - 0.28, minf(0.72, y1 - floor_y - 1.1))
					_side_leaf(kits, hw, z0, z1, y0, y1, {"win": win, "handle_z": z0 + 0.12, "handle_y": floor_y + 0.95,
						"crease": floor_y + 0.78})
					var move := Vector3(0.085, 0, z1 - z0 + 0.03) if kind == "slider" else Vector3(-(LEAF_T + 0.03), 0, z1 - z0 + 0.02)
					out.append({"name": "D%d_0" % si, "kits": kits, "door": si, "where": "side", "kind": kind,
						"open": Transform3D(Basis.IDENTITY, move)})
				_:
					var kits := _leaf_kits()
					var win := Rect2()
					if glazed:
						win = Rect2(z0 + 0.13, floor_y + 1.05, z1 - z0 - 0.26, minf(0.55, y1 - floor_y - 1.2))
					_side_leaf(kits, hw, z0, z1, y0, y1, {"win": win, "handle_z": z1 - 0.1, "handle_y": floor_y + 0.95})
					out.append({"name": "D%d_0" % si, "kits": kits, "door": si, "where": "side", "kind": kind,
						"open": _swing(Vector3(hw, 0, z0), Vector3.UP, deg_to_rad(105.0))})
		else:
			var x0 := float(sd["x0"]) + DOOR_GAP
			var x1 := float(sd["x1"]) - DOOR_GAP
			var rear := str(b["rear_door"])
			match rear:
				"barn":
					for li in 2:
						var a := x0 if li == 0 else DOOR_GAP * 0.5
						var c := -DOOR_GAP * 0.5 if li == 0 else x1
						var kits := _leaf_kits()
						var win := Rect2()
						if glazed or str(b["id"]) == "van_shell":
							win = Rect2(a + 0.12, y1 - 0.78, c - a - 0.24, 0.62)
						_rear_leaf(kits, zr, a, c, y0, y1, {"win": win, "handle_x": (c - 0.09) if li == 0 else (a + 0.09),
							"handle_y": floor_y + 0.95, "rods": str(b["id"]) != "van_shell" and not glazed})
						var hinge := Vector3(a if li == 0 else c, 0, zr)
						out.append({"name": "D%d_%d" % [si, li], "kits": kits, "door": si, "where": "rear", "kind": rear,
							"open": _swing(hinge, Vector3.UP, deg_to_rad(-112.0 if li == 0 else 112.0))})
				"roll_up":
					var kits := _leaf_kits()
					_rear_leaf(kits, zr, x0, x1, y0, y1, {"slats": true, "handle_x": 0.0, "handle_y": y0 + 0.12})
					var sc := 0.07
					out.append({"name": "D%d_0" % si, "kits": kits, "door": si, "where": "rear", "kind": rear,
						"open": Transform3D(Basis.from_scale(Vector3(1, sc, 1)), Vector3(0, y1 * (1.0 - sc), -0.03))})
				_:
					var kits := _leaf_kits()
					_rear_leaf(kits, zr, x0, x1, y0, y1, {"win": Rect2(x0 + 0.2, y1 - 0.8, x1 - x0 - 0.4, 0.6) if glazed else Rect2(),
						"handle_x": 0.0, "handle_y": y0 + 0.15})
					out.append({"name": "D%d_0" % si, "kits": kits, "door": si, "where": "rear", "kind": rear,
						"open": _swing(Vector3(0, y1, zr), Vector3.RIGHT, deg_to_rad(-82.0))})
	return out


static func _leaf_kits() -> Dictionary:
	return _kits(["body", "trim", "dark", "liner", "pane", "metal", "door"])


## A turn of `angle` about the line through `pivot` along `axis`.
static func _swing(pivot: Vector3, axis: Vector3, angle: float) -> Transform3D:
	var bas := Basis(axis.normalized(), angle)
	return Transform3D(bas, pivot - bas * pivot)


## A leaf in a side wall (the curb side): skins at x = hw and hw - LEAF_T
## between za..zb and ya..yb, an optional window, edges, a handle.
static func _side_leaf(kits: Dictionary, hw: float, za: float, zb: float, ya: float, yb: float, o: Dictionary) -> void:
	var frame := str(o.get("frame", "body"))
	var ok: _K = kits[frame]
	var ik: _K = kits["liner"] if frame == "body" else kits[frame]
	var win: Rect2 = o.get("win", Rect2())
	var holes: Array = [win] if win.size.x > 0.02 and win.size.y > 0.02 else []
	var xo := hw
	var xi := hw - LEAF_T
	var rect := _rect_poly(za, ya, zb, yb)
	var polys := _cut_panel(rect, holes)
	_emit_polys(ok, polys, func(p: Vector2) -> Vector3: return Vector3(xo, p.y, p.x), Vector3.RIGHT)
	_emit_polys(ik, polys, func(p: Vector2) -> Vector3: return Vector3(xi, p.y, p.x), Vector3.LEFT)
	var ek: _K = kits["dark"]
	# The leaf's edges (outward-facing: the reverse of an opening's jamb).
	ek.quad(Vector3(xo, ya, za), Vector3(xo, ya, zb), Vector3(xi, ya, zb), Vector3(xi, ya, za), Vector3.DOWN)
	ek.quad(Vector3(xo, yb, za), Vector3(xo, yb, zb), Vector3(xi, yb, zb), Vector3(xi, yb, za), Vector3.UP)
	ek.quad(Vector3(xo, ya, za), Vector3(xi, ya, za), Vector3(xi, yb, za), Vector3(xo, yb, za), Vector3.FORWARD)
	ek.quad(Vector3(xo, ya, zb), Vector3(xi, ya, zb), Vector3(xi, yb, zb), Vector3(xo, yb, zb), Vector3.BACK)
	if not holes.is_empty():
		_side_jamb(kits["trim"], 1.0, xo, xi, win)
		if frame == "body":
			_side_gasket(kits["trim"], 1.0, xo, win, 0.024)
		var gx := hw - 0.014
		(kits["pane"] as _K).quad(Vector3(gx, win.position.y, win.position.x), Vector3(gx, win.position.y, win.end.x),
			Vector3(gx, win.end.y, win.end.x), Vector3(gx, win.end.y, win.position.x), Vector3.RIGHT)
	if o.has("handle_z"):
		var hz := float(o["handle_z"])
		var hy := float(o["handle_y"])
		(kits["dark"] as _K).box(Vector3(xo + 0.003, hy, hz), Vector3(0.006, 0.075, 0.2))
		(kits["trim"] as _K).box(Vector3(xo + 0.022, hy, hz), Vector3(0.02, 0.03, 0.15))
		(kits["trim"] as _K).box(Vector3(xi - 0.02, hy, hz), Vector3(0.03, 0.03, 0.12))
	if o.has("crease"):
		(kits["dark"] as _K).box(Vector3(xo + 0.001, float(o["crease"]), (za + zb) * 0.5), Vector3(0.003, 0.012, zb - za - 0.02))


## A leaf in the rear wall: skins at z = zr and zr - LEAF_T between xa..xb.
static func _rear_leaf(kits: Dictionary, zr: float, xa: float, xb: float, ya: float, yb: float, o: Dictionary) -> void:
	var slats := bool(o.get("slats", false))
	var ok: _K = kits["door"] if slats else kits["body"]
	var win: Rect2 = o.get("win", Rect2())
	var holes: Array = [win] if win.size.x > 0.02 and win.size.y > 0.02 else []
	var zo := zr
	var zi := zr - LEAF_T
	var polys := _cut_panel(_rect_poly(xa, ya, xb, yb), holes)
	_emit_polys(ok, polys, func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, zo), Vector3.BACK)
	_emit_polys(kits["liner"], polys, func(p: Vector2) -> Vector3: return Vector3(p.x, p.y, zi), Vector3.FORWARD)
	var ek: _K = kits["dark"]
	ek.quad(Vector3(xa, ya, zo), Vector3(xb, ya, zo), Vector3(xb, ya, zi), Vector3(xa, ya, zi), Vector3.DOWN)
	ek.quad(Vector3(xa, yb, zo), Vector3(xb, yb, zo), Vector3(xb, yb, zi), Vector3(xa, yb, zi), Vector3.UP)
	ek.quad(Vector3(xa, ya, zo), Vector3(xa, ya, zi), Vector3(xa, yb, zi), Vector3(xa, yb, zo), Vector3.LEFT)
	ek.quad(Vector3(xb, ya, zo), Vector3(xb, ya, zi), Vector3(xb, yb, zi), Vector3(xb, yb, zo), Vector3.RIGHT)
	var tk: _K = kits["trim"]
	if not holes.is_empty():
		_end_jamb(tk, zo, zi, win)
		(kits["pane"] as _K).quad(Vector3(win.position.x, win.position.y, zo - 0.014), Vector3(win.end.x, win.position.y, zo - 0.014),
			Vector3(win.end.x, win.end.y, zo - 0.014), Vector3(win.position.x, win.end.y, zo - 0.014), Vector3.BACK)
		for yy in [win.position.y, win.end.y]:
			tk.box(Vector3(win.position.x + win.size.x * 0.5, yy, zo + 0.004), Vector3(win.size.x + 0.024, 0.024, 0.012))
		for xx in [win.position.x, win.end.x]:
			tk.box(Vector3(xx, win.position.y + win.size.y * 0.5, zo + 0.004), Vector3(0.024, win.size.y + 0.024, 0.012))
	if slats:
		var y := ya + 0.1
		while y < yb - 0.02:
			ek.box(Vector3((xa + xb) * 0.5, y, zo + 0.002), Vector3(xb - xa, 0.01, 0.006))
			y += 0.15
		(kits["metal"] as _K).box(Vector3(float(o.get("handle_x", 0.0)), float(o.get("handle_y", ya + 0.12)), zo + 0.02), Vector3(0.3, 0.04, 0.04))
		tk.box(Vector3((xa + xb) * 0.5, ya + 0.025, zo + 0.006), Vector3(xb - xa, 0.05, 0.014))
		return
	if bool(o.get("rods", false)):
		# A box body's lock rods.
		var mk: _K = kits["metal"]
		var rx := (xa + xb) * 0.5
		mk.cylinder(Vector3(rx, (ya + yb) * 0.5, zo + 0.025), 0.014, yb - ya - 0.04, Vector3.UP, 6)
		mk.box(Vector3(rx, ya + 0.9, zo + 0.03), Vector3(0.22, 0.03, 0.02))
	if o.has("handle_x"):
		ek.box(Vector3(float(o["handle_x"]), float(o["handle_y"]), zo + 0.003), Vector3(0.16, 0.075, 0.006))
		tk.box(Vector3(float(o["handle_x"]), float(o["handle_y"]), zo + 0.02), Vector3(0.12, 0.028, 0.02))
	# Hinges on the outer edge.
	var hx := xa if absf(xa) > absf(xb) else xb
	for hy in [ya + 0.25, (ya + yb) * 0.5, yb - 0.25]:
		tk.box(Vector3(hx, hy, zo + 0.01), Vector3(0.05, 0.09, 0.02))


## Open the leaves of door `door` (an index in VehicleDesign.door_spans; -1 =
## every door) by `t` (0 shut … 1 open). Finds the "Doors" node on the model.
static func set_doors_open(model: Node3D, door: int, t: float) -> void:
	var root := _wheel_root(model)
	if root == null:
		return
	var holder := root.get_node_or_null("Doors")
	if holder == null:
		return
	t = clampf(t, 0.0, 1.0)
	var e := t * t * (3.0 - 2.0 * t)
	for c in holder.get_children():
		var leaf := c as Node3D
		if leaf == null or (door >= 0 and int(leaf.get_meta("door", -1)) != door):
			continue
		var open: Transform3D = leaf.get_meta("open_xf", Transform3D.IDENTITY)
		leaf.transform = Transform3D.IDENTITY.interpolate_with(open, e)


## The doorways someone can walk through, for the collision and the runtime
## (VehicleWalkIn), vehicle-local: [{door (index in door_spans), where "side" |
## "rear", kind, a, b (the gap along the wall: z for a side door, x for the
## rear), y0, y1 (the drawn leaf), sill (the floor inside), plane (the wall's
## x or z), mid (the drawn door's middle along the wall), cargo}]. A drawn
## door narrower than WALK_GAP_M still gets that much room.
static func door_gaps(d: Dictionary) -> Array:
	var out: Array = []
	var b: Dictionary = d["body"]
	var hw := float(b["w"]) * 0.5
	var floor_y := float(b["floor_y"])
	var spans := VehicleDesign.door_spans(d)
	for si in spans.size():
		var sd: Dictionary = spans[si]
		var side := str(sd["where"]) == "side"
		var a := float(sd["z0"]) if side else float(sd["x0"])
		var c := float(sd["z1"]) if side else float(sd["x1"])
		var mid := (a + c) * 0.5
		var half := maxf((c - a) * 0.5, WALK_GAP_M * 0.5)
		var ga := mid - half
		var gb := mid + half
		if side:
			ga = maxf(ga, float(b["z0"]) + 0.12)
			gb = minf(gb, float(b["z1"]) - 0.12)
		out.append({"door": si, "where": "side" if side else "rear",
			"kind": str(sd.get("kind", b["side_door"])) if side else str(b["rear_door"]),
			"a": ga, "b": gb, "y0": float(sd["y0"]), "y1": float(sd["y1"]), "sill": floor_y,
			"plane": hw if side else float(b["z1"]), "mid": mid})
	return out


## The walk-in collision as boxes [[centre, size], …], vehicle-local: the
## floor, the walls with the doorways left open, the roof (never lower than
## standing room), the ends, the cab and the hood, and the furniture a little
## slimmer than drawn (aisles are sized for hips, the player's capsule is
## 0.7 m across). Doors that are shut are the runtime's (VehicleWalkIn).
static func collision_boxes(d: Dictionary) -> Array:
	var out: Array = []
	var b: Dictionary = d["body"]
	var cg: Dictionary = d["cab_geo"]
	var house: Dictionary = d["house"]
	var style := str(cg["style"])
	var integral := bool(d["integral"])
	var hw := float(b["w"]) * 0.5
	var y0 := float(b["y0"])
	var z0 := float(b["z0"])
	var z1 := float(b["z1"])
	var fy := float(b["floor_y"])
	var H := float(b["h"])
	var T := 0.1
	var roof_y := maxf(float(house["ceil_y"]), fy + WALK_HEAD_M)
	var top := maxf(H, roof_y + T)
	var van := style == "full_van" and integral
	# Where the room starts: at the dash for a van, the windshield for other
	# integral bodies, the bulkhead otherwise.
	var zf := z0
	if van:
		zf = float(cg["z0"]) + nose_hood(d) + 0.5
	var add := func(x0: float, x1: float, ya: float, yb: float, za: float, zb: float) -> void:
		if x1 - x0 > 0.005 and yb - ya > 0.005 and zb - za > 0.005:
			out.append([Vector3((x0 + x1) * 0.5, (ya + yb) * 0.5, (za + zb) * 0.5), Vector3(x1 - x0, yb - ya, zb - za)])
	add.call(-hw, hw, minf(y0, fy - 0.25), fy, zf, z1)
	add.call(-hw, hw, roof_y, top, zf, z1)
	add.call(-hw, hw, fy, top, zf - T, zf)
	var gaps := door_gaps(d)
	# The road side is solid; the curb side and the rear leave their doorways.
	add.call(-hw, -hw + T, fy, top, zf, z1)
	var cuts: Array = []
	for gp in gaps:
		if str((gp as Dictionary)["where"]) == "side":
			cuts.append([float(gp["a"]), float(gp["b"])])
	cuts.sort_custom(func(p, q): return float(p[0]) < float(q[0]))
	var at := zf
	for c in cuts:
		add.call(hw - T, hw, fy, top, at, float(c[0]))
		at = maxf(at, float(c[1]))
	add.call(hw - T, hw, fy, top, at, z1)
	var rcut: Array = []
	for gp in gaps:
		if str((gp as Dictionary)["where"]) == "rear":
			rcut = [float(gp["a"]), float(gp["b"])]
	if rcut.is_empty():
		add.call(-hw, hw, fy, top, z1 - T, z1)
	else:
		add.call(-hw, float(rcut[0]), fy, top, z1 - T, z1)
		add.call(float(rcut[1]), hw, fy, top, z1 - T, z1)
	# The cab and the hood ahead of the room.
	if style != "none":
		var cz0 := float(cg["z0"])
		var cw := float(cg["w"]) * 0.5
		var cyb := maxf(float(cg["frame_h"]) - 0.32, 0.28)
		if van:
			add.call(-cw, cw, cyb, float(cg["frame_h"]) + 0.6, cz0, zf)
			add.call(-cw, cw, cyb, float(cg["h"]), zf - 0.02, zf)
		elif integral:
			if float(cg["hood"]) > 0.05:
				add.call(-cw * 0.82, cw * 0.82, cyb, float(cg["frame_h"]) + 0.75, cz0, z0)
		else:
			var hood := float(cg["hood"])
			if hood > 0.05:
				add.call(-cw, cw, cyb, float(cg["frame_h"]) + 0.6, cz0, cz0 + hood)
			add.call(-cw, cw, cyb, float(cg["h"]), cz0 + hood, minf(cz0 + float(cg["cab_len"]), z0))
	# Furniture standing on the floor.
	var hz0 := float(house["z0"])
	for e0 in d["interior"]:
		var e: Dictionary = e0
		var by := float(e["base_y"])
		var ty := float(e["top_y"])
		if ty - by < 0.12 or by > fy + 1.2 or str(e["type"]) == "light":
			continue
		var fx := maxf(float(e["fx"]) - 0.26, 0.06)
		var fz := maxf(float(e["fz"]) - 0.26, 0.06)
		var x := float(e["x"])
		var z := float(e["z"])
		if z + fz * 0.5 < hz0 - 0.5:
			continue
		add.call(x - fx * 0.5, x + fx * 0.5, by, ty, z - fz * 0.5, z + fz * 0.5)
	return out


static func _collision_mesh(d: Dictionary) -> ArrayMesh:
	var k := _K.new()
	for bx in collision_boxes(d):
		k.box(bx[0], bx[1])
	if k.count == 0:
		return null
	var mesh := ArrayMesh.new()
	k.st.commit(mesh)
	return mesh


## The body's cross-section, counter-clockwise from the bottom left: straight
## walls, a rounded corner of radius r, a crown rising to the centre.
static func _profile(hw: float, y0: float, H: float, r: float, crown: float,
		ya: float = -1.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.append(Vector2(-hw, y0))
	pts.append(Vector2(hw, y0))
	var yw := H - crown - r
	# A vertex up the wall at `ya`, mirrored on the left.
	if ya > y0 and ya < yw - 0.01:
		pts.append(Vector2(hw, ya))
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


## How far a skirted body's wheel well reaches in (clear of a dually pair).
const ARCH_DEPTH := 0.55


## The fiberglass cap over a cutaway's cab (an Aerotech-style shuttle): a
## wedge lofted forward from the box's front between the cab roof and the
## box's top, narrowing to a rounded nose, with amber clearance lamps on its
## brow.
static func _front_cap(d: Dictionary, sh: Dictionary) -> void:
	var b: Dictionary = d["body"]
	var cg: Dictionary = d["cab_geo"]
	var hw := float(b["w"]) * 0.5
	var H := float(b["h"])
	var er := float(b.get("end_r", 0.0))
	var zf := float(b["z0"])
	var L := float(b.get("cap_len", 0.7))
	var ch := float(cg["h"]) + 0.01
	if H - ch < 0.25:
		return
	var ny := ch + (H - ch) * 0.42
	var keys := [
		[-0.06, hw - er * 0.35, ch, H - 0.05, 0.14, 0.05],
		[L * 0.35, hw * 0.97 - er * 0.2, ch + 0.015, H - 0.07 - (H - ny) * 0.12, 0.14, 0.05],
		[L * 0.78, hw * 0.92 - er * 0.1, ch + 0.05, ny + (H - ny) * 0.45, 0.12, 0.05],
		[L, hw * 0.86, ny - 0.045, ny + 0.045, 0.044, 0.044]]
	var rings: Array = []
	for kd in keys:
		rings.append(_rr_ring(float(kd[1]), float(kd[2]), float(kd[3]), float(kd[4]), float(kd[5]), zf - float(kd[0])))
	_loft(rings, func(_k, _i): return sh["roof"], Callable(), sh["roof"])
	var u := L * 0.56
	var k1: Array = keys[1]
	var k2: Array = keys[2]
	var t := (u - float(k1[0])) / maxf(float(k2[0]) - float(k1[0]), 0.01)
	var ly := lerpf(float(k1[3]), float(k2[3]), t)
	for lx in [-0.62, -0.18, 0.0, 0.18, 0.62]:
		(sh["amber"] as _K).box(Vector3(lx, ly + 0.01, zf - u), Vector3(0.09, 0.035, 0.06))


static func _rake(y: float, from_y: float, H: float, top: float) -> float:
	if top <= 0.0 or H <= from_y:
		return 0.0
	return top * clampf((y - from_y) / (H - from_y), 0.0, 1.0)


## The step under a bus door hangs this far below its sill.
const BUS_STEP_M := 0.25


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
	# An integral body (a bus, a step van, a Class A) is one room from the
	# windshield back: its floor runs under the driver too.
	var fz0 := hz0
	var cgd: Dictionary = d["cab_geo"]
	if bool(d["integral"]) and str(cgd["style"]) != "full_van":
		fz0 = float((d["body"] as Dictionary)["z0"]) + 0.05
	(g["floor"] as _K).box(Vector3(0, fy - 0.03, (fz0 + hz1) * 0.5), Vector3(hw * 2.0, 0.06, hz1 - fz0))
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
				# A tap over the sink and two burners on the hob.
				var mk: _K = g["metal"]
				var back := Vector3(signf(x) * (fx * 0.5 - 0.06), 0, 0) if along else Vector3(0, 0, -(fz * 0.5 - 0.06))
				mk.cylinder(sink + back + Vector3(0, 0.11, 0), 0.012, 0.22, Vector3.UP, 6)
				mk.box(sink + back * 0.55 + Vector3(0, 0.21, 0), Vector3(0.024, 0.02, 0.024) + back.abs() * 0.9)
				for k in [-1.0, 1.0]:
					var bc := stove + (Vector3(0, 0, k * 0.1) if along else Vector3(k * 0.1, 0, 0))
					mk.cylinder(bc + Vector3(0, 0.01, 0), 0.07, 0.008, Vector3.UP, 12)
				_cabinet_front(dark, mk, x, z, fx, fz, y0, y1 - 0.06)
		"fridge":
			white.box(Vector3(x, (y0 + y1) * 0.5, z), Vector3(fx, y1 - y0, fz))
			# The door's seam (a freezer door over a tall one) and its handles.
			var ffx := x + (-fx * 0.5 - 0.003 if x > 0.0 else fx * 0.5 + 0.003)
			if y1 - y0 > 1.0:
				dark.box(Vector3(ffx, y1 - 0.42, z), Vector3(0.004, 0.008, fz * 0.96))
			for hy in [y1 - 0.3, y1 - 0.6]:
				if hy > y0 + 0.2:
					(g["metal"] as _K).box(Vector3(ffx + (-0.012 if x > 0.0 else 0.012), hy, z + fz * 0.36), Vector3(0.02, 0.16, 0.02))
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
			_cabinet_front(dark, g["metal"], x, z, fx, fz, y0, y1)
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


## A cabinet's face toward the aisle: the seams between its doors (each
## about 45 cm wide) and a pull on each.
static func _cabinet_front(dark: _K, mk: _K, x: float, z: float, fx: float, fz: float, y0: float, y1: float) -> void:
	if y1 - y0 < 0.2:
		return
	var toward := -1.0 if x > 0.0 else 1.0
	var along_z := fz >= fx
	var face := (x + toward * (fx * 0.5 + 0.003)) if along_z else (z + (fz * 0.5 + 0.003))
	var run := fz if along_z else fx
	var n := maxi(int(round(run / 0.45)), 1)
	var c0 := (z if along_z else x) - run * 0.5
	var ym := (y0 + y1) * 0.5
	for i in n + 1:
		var u := c0 + run * float(i) / float(n)
		if i > 0 and i < n:
			if along_z:
				dark.box(Vector3(face, ym, u), Vector3(0.004, y1 - y0 - 0.04, 0.008))
			else:
				dark.box(Vector3(u, ym, face), Vector3(0.008, y1 - y0 - 0.04, 0.004))
		if i < n:
			var hu := u + run / float(n) * (0.82 if i % 2 == 0 else 0.18)
			var hy := y1 - 0.1 if y0 < 1.3 else y0 + 0.1
			if along_z:
				mk.box(Vector3(face + toward * 0.012, hy, hu), Vector3(0.016, 0.014, 0.1))
			else:
				mk.box(Vector3(hu, hy, face + 0.012), Vector3(0.1, 0.014, 0.016))
	if along_z:
		dark.box(Vector3(face, y0 + 0.05, z), Vector3(0.004, 0.1, run))
	else:
		dark.box(Vector3(x, y0 + 0.05, face), Vector3(run, 0.1, 0.004))


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
	var mat_id := StructureMaterials.infer_id(c, metallic, rough, c.a)
	return ParametricMaterialLibrary.make(mat_id, c)


static func _emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.4
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

	## A surface of revolution about `axis` through `center`: `prof` is
	## (distance along the axis, radius) run so the outside is on the left of
	## its direction (up the near side, across the tread, down the far side).
	func lathe(center: Vector3, axis: Vector3, prof: PackedVector2Array, sides: int = 20) -> void:
		axis = axis.normalized()
		var ref := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
		var e1 := axis.cross(ref).normalized()
		var e2 := axis.cross(e1).normalized()
		for j in prof.size() - 1:
			var p := prof[j]
			var q := prof[j + 1]
			var dv := q - p
			if dv.length() < 1e-6:
				continue
			var na := -dv.y / dv.length()
			var nr := dv.x / dv.length()
			for i in sides:
				var a0 := TAU * float(i) / sides
				var a1 := TAU * float(i + 1) / sides
				var d0 := e1 * cos(a0) + e2 * sin(a0)
				var d1 := e1 * cos(a1) + e2 * sin(a1)
				var n0 := (axis * na + d0 * nr).normalized()
				var n1 := (axis * na + d1 * nr).normalized()
				var v00 := center + axis * p.x + d0 * p.y
				var v01 := center + axis * p.x + d1 * p.y
				var v10 := center + axis * q.x + d0 * q.y
				var v11 := center + axis * q.x + d1 * q.y
				var f := (n0 + n1).normalized()
				if p.y < 1e-6:
					tri_n(v00, v11, v10, f, n1, n0, f)
				elif q.y < 1e-6:
					tri_n(v00, v01, v10, n0, n1, f, f)
				else:
					quad_n(v00, v01, v11, v10, n0, n1, n1, n0, f)

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

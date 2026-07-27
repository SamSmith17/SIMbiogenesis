class_name PipeKit
extends RefCounted

## Descriptor for a physical pipe-fittings kit (straight + elbows).
## Loaded from JSON under res://core/conduits/data/; meshes are ArrayMesh .res.
## Multi-size US Sch40 family shares geometry; ABS/PVC tint via ConduitKinds.

const DATA_DIR := "res://core/conduits/data/"
const FAMILY_US_SCH40 := "us_sch40"
const INVENTORY_PATH := DATA_DIR + "fittings_inventory_us_sch40.json"
const SCH40_SIZES_IN := [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0]

## kit_id → JSON filename (includes legacy abs_dwv alias → 2.5″ meshes).
const KITS := {
	"us_sch40_0_5": "pipe_kit_us_sch40_0_5.json",
	"us_sch40_0_75": "pipe_kit_us_sch40_0_75.json",
	"us_sch40_1": "pipe_kit_us_sch40_1.json",
	"us_sch40_1_25": "pipe_kit_us_sch40_1_25.json",
	"us_sch40_1_5": "pipe_kit_us_sch40_1_5.json",
	"us_sch40_2": "pipe_kit_us_sch40_2.json",
	"us_sch40_2_5": "pipe_kit_us_sch40_2_5.json",
	"us_sch40_3": "pipe_kit_us_sch40_3.json",
	"us_sch40_4": "pipe_kit_us_sch40_4.json",
	"us_sch40_5": "pipe_kit_us_sch40_5.json",
	"us_sch40_6": "pipe_kit_us_sch40_6.json",
	"us_sch40_8": "pipe_kit_us_sch40_8.json",
	"abs_dwv": "pipe_kit_abs_dwv.json",
}

var kit_id: String = ""
var revision: int = 1
var nominal_od_m: float = 0.07
var source_glb: String = ""
var size_in: float = 0.0
var family: String = ""
var parts: Dictionary = {}  ## bend_key ("0"|"45"|"90") -> part dict


static func size_token(size_in: float) -> String:
	var nearest := nearest_size_in(size_in)
	var whole := int(floor(nearest + 1e-6))
	var frac := nearest - float(whole)
	if frac < 0.01:
		return str(whole)
	if absf(frac - 0.5) < 0.01:
		return "%d_5" % whole if whole > 0 else "0_5"
	if absf(frac - 0.25) < 0.01:
		return "%d_25" % whole if whole > 0 else "0_25"
	if absf(frac - 0.75) < 0.01:
		return "%d_75" % whole if whole > 0 else "0_75"
	return str(nearest).replace(".", "_")


static func nearest_size_in(size_in: float) -> float:
	var best := SCH40_SIZES_IN[0]
	var best_d := INF
	for s: float in SCH40_SIZES_IN:
		var d := absf(s - size_in)
		if d < best_d:
			best_d = d
			best = s
	return best


static func kit_id_for_size(family: String, size_in: float) -> String:
	if family.is_empty():
		family = FAMILY_US_SCH40
	return "%s_%s" % [family, size_token(size_in)]


static func size_label(size_in: float) -> String:
	var s := nearest_size_in(size_in)
	var whole := int(floor(s + 1e-6))
	var frac := s - float(whole)
	if frac < 0.01:
		return "%d″" % whole
	if absf(frac - 0.5) < 0.01:
		return "½″" if whole == 0 else "%d½″" % whole
	if absf(frac - 0.25) < 0.01:
		return "¼″" if whole == 0 else "%d¼″" % whole
	if absf(frac - 0.75) < 0.01:
		return "¾″" if whole == 0 else "%d¾″" % whole
	return "%.2f″" % s


static func load_inventory() -> Dictionary:
	if not FileAccess.file_exists(INVENTORY_PATH):
		return {}
	var f := FileAccess.open(INVENTORY_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed as Dictionary if parsed is Dictionary else {}


# Process-lifetime cache: load_kit does a JSON read + per-part load() + crease_normals()
# SurfaceTool rebuild, and it's called on the drag-preview hot path (route controller
# + style modal) just to read nominal_od_m. Kit data is immutable and already shared
# by reference (ConduitManager._get_pipe_kit hands out the same instance), so caching
# here is safe and removes the per-tick remesh cost. `false` caches a miss.
static var _kit_cache: Dictionary = {}

static func load_kit(kit_id: String) -> PipeKit:
	if _kit_cache.has(kit_id):
		var hit: Variant = _kit_cache[kit_id]
		return hit as PipeKit if hit is PipeKit else null
	var kit := _load_kit_uncached(kit_id)
	_kit_cache[kit_id] = kit if kit != null else false
	return kit


static func _load_kit_uncached(kit_id: String) -> PipeKit:
	var kit := PipeKit.new()
	kit.kit_id = kit_id
	var fname := str(KITS.get(kit_id, ""))
	if fname.is_empty():
		# Allow resolving family+size ids that aren't in the const map yet.
		fname = "pipe_kit_%s.json" % kit_id
	var path := DATA_DIR + fname
	if not FileAccess.file_exists(path):
		push_warning("PipeKit: missing %s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = parsed
	kit.revision = int(d.get("revision", 1))
	kit.nominal_od_m = float(d.get("nominal_od_m", 0.07))
	kit.source_glb = str(d.get("source_glb", ""))
	kit.size_in = float(d.get("size_in", 0.0))
	kit.family = str(d.get("family", ""))
	var parts_raw: Dictionary = d.get("parts", {}) as Dictionary
	for k: Variant in parts_raw.keys():
		var p: Dictionary = (parts_raw[k] as Dictionary).duplicate(true)
		var mesh_path := str(p.get("mesh_res", ""))
		if not mesh_path.is_empty() and ResourceLoader.exists(mesh_path):
			var mesh := load(mesh_path) as Mesh
			# Elbows from generate_normals() are over-smoothed (melted look).
			# Crease ~32° keeps cylinder barrels soft but hardens collar rims.
			if mesh != null and str(k) != "0":
				mesh = crease_normals(mesh, 32.0)
			p["mesh"] = mesh
		kit.parts[str(k)] = p
	if not kit.parts.has("0") or kit.parts["0"].get("mesh") == null:
		push_warning("PipeKit: straight mesh missing for %s" % kit_id)
		return null
	return kit


## Rebuild mesh normals with an angle crease so elbows read as hard fittings,
## not a soft rubber bend. Faces whose normals diverge by more than crease_deg
## do not share a vertex normal (edge is hard).
static func crease_normals(src: Mesh, crease_deg: float = 32.0) -> ArrayMesh:
	if src == null:
		return null
	var out := ArrayMesh.new()
	var cos_keep := cos(deg_to_rad(clampf(crease_deg, 5.0, 80.0)))
	for s: int in range(src.get_surface_count()):
		var arrays := src.surface_get_arrays(s)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
				if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			# Non-indexed: treat every 3 verts as a triangle.
			indices = PackedInt32Array()
			indices.resize(verts.size())
			for i: int in range(verts.size()):
				indices[i] = i
		# Face normals + vertex → incident faces.
		var face_n: Array = []  ## Vector3 per face
		var vert_faces: Array = []  ## Array of face indices per vertex
		vert_faces.resize(verts.size())
		for vi: int in range(verts.size()):
			vert_faces[vi] = []
		var fi := 0
		var i := 0
		while i + 2 < indices.size():
			var ia := indices[i]
			var ib := indices[i + 1]
			var ic := indices[i + 2]
			i += 3
			if ia < 0 or ib < 0 or ic < 0 \
					or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
				continue
			var e1: Vector3 = verts[ib] - verts[ia]
			var e2: Vector3 = verts[ic] - verts[ia]
			var n := e1.cross(e2)
			if n.length_squared() < 1e-16:
				n = Vector3.UP
			else:
				n = n.normalized()
			face_n.append(n)
			(vert_faces[ia] as Array).append(fi)
			(vert_faces[ib] as Array).append(fi)
			(vert_faces[ic] as Array).append(fi)
			fi += 1
		# Emit unique corners: each triangle corner gets a creased normal.
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var face_i := 0
		i = 0
		while i + 2 < indices.size():
			var tri := [indices[i], indices[i + 1], indices[i + 2]]
			i += 3
			if face_i >= face_n.size():
				break
			var fn: Vector3 = face_n[face_i]
			for corner: int in tri:
				var acc := Vector3.ZERO
				var count := 0
				for ofi: Variant in vert_faces[corner] as Array:
					var on: Vector3 = face_n[int(ofi)]
					if on.dot(fn) >= cos_keep:
						acc += on
						count += 1
				var cn := fn if count == 0 else (acc / float(count)).normalized()
				st.set_normal(cn)
				st.add_vertex(verts[corner])
			face_i += 1
		out = st.commit(out)
	return out if out.get_surface_count() > 0 else src as ArrayMesh


func has_elbow(bend_deg: float) -> bool:
	return parts.has(_bend_key(bend_deg)) and parts[_bend_key(bend_deg)].get("mesh") != null


func part(bend_deg: float) -> Dictionary:
	return parts.get(_bend_key(bend_deg), {}) as Dictionary


func straight_template_length_m() -> float:
	return float(part(0.0).get("centerline_length_m", 0.5))


func elbow_takeout_m(bend_deg: float) -> float:
	## Distance from geometric corner (tangent intersection) to each socket.
	return float(part(bend_deg).get("takeout_m", 0.0))


func elbow_centerline_radius_m(bend_deg: float) -> float:
	return float(part(bend_deg).get("centerline_radius_m", elbow_takeout_m(bend_deg)))


func supported_bend_degs() -> Array:
	var out: Array = []
	for k: String in parts.keys():
		var deg := float(k)
		if deg > 0.5 and parts[k].get("mesh") != null:
			out.append(deg)
	out.sort()
	return out


static func _bend_key(bend_deg: float) -> String:
	if bend_deg < 0.5:
		return "0"
	return str(int(round(bend_deg)))


## Classify a corner turn into a kit elbow angle, or -1 if unsupported.
func classify_bend_deg(turn_deg: float, tol_deg: float = 8.0) -> float:
	var t := absf(turn_deg)
	if t < 2.0:
		return 0.0
	var best := -1.0
	var best_d := INF
	for deg: float in supported_bend_degs():
		var d := absf(t - deg)
		if d < best_d:
			best_d = d
			best = deg
	if best_d <= tol_deg:
		return best
	return -1.0

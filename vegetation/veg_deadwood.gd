class_name VegDeadwood
extends RefCounted

## Forest-floor deadwood: old stumps and fallen, mossy logs among the trees.
##
## A Pacific Northwest second-growth forest reads as one because of what the
## logging left behind — springboard-notched old-growth stumps and nurse logs
## under the young canopy. Nothing about the deadwood is STORED: like the
## generated forest, every piece is derived from the trees already standing
## (painted + auto records) by a position hash, so it survives reloads, moves
## with re-painting and costs no file. A style turns it on:
##
##   deadwood_per_100_trees  pieces per hundred trees (0 = off, the default)
##   deadwood_log_share      0..1, share of pieces that are fallen logs
##   deadwood_stump_models   comma-separated user model ids (Library imports)
##                           used as stumps; empty = logs only
##   deadwood_visibility_m   draw distance (built once, FADE_SELF)
##
## Rendering: one MultiMesh per stump model / logs per 256 m chunk, so each
## chunk culls on its own. Stumps keep the model's own materials with a moss
## overlay on the up-facing surfaces; logs are a procedural capped cylinder
## under deadwood_log.gdshader (bark, moss on top, pale cut ends).

const ROOT_NAME := "Deadwood"
const KEY_DENSITY := "deadwood_per_100_trees"
const KEY_LOG_SHARE := "deadwood_log_share"
const KEY_MODELS := "deadwood_stump_models"
const KEY_VIS := "deadwood_visibility_m"
const DEFAULT_VIS_M := 180.0
const CHUNK_M := 256.0
## A stump bigger than this (metres, footprint / height) is scaled down to it:
## some library stumps carry a whole root plate several metres across.
const STUMP_MAX_SPAN_M := 3.2
const STUMP_MAX_H_M := 2.6
## A model whose height is outside this range is not in metres (a cm or inch
## export): it is fitted to STUMP_FALLBACK_H_M instead of taken at face value.
const STUMP_SANE_H := Vector2(0.3, 6.0)
const STUMP_FALLBACK_H_M := 1.4
const LOG_SHADER := preload("res://vegetation/deadwood_log.gdshader")
const MOSS_SHADER := preload("res://vegetation/deadwood_moss.gdshader")
const STUMP_SHADER := preload("res://vegetation/deadwood_stump.gdshader")

static var _stump_cache: Dictionary = {}   # model_id -> ArrayMesh (or null)
static var _log_mesh: ArrayMesh = null
static var _log_mat: ShaderMaterial = null
static var _moss_mat: ShaderMaterial = null
static var _stump_mat: ShaderMaterial = null


static func enabled(settings: Dictionary) -> bool:
	return float(settings.get(KEY_DENSITY, 0.0)) > 0.0


## Cheap deterministic 0..1 hash of a position + salt (pure, double precision).
static func hash01(x: float, z: float, salt: float) -> float:
	var h := sin(x * 12.9898 + z * 78.233 + salt * 37.719) * 43758.5453
	return h - floor(h)


## The deadwood plan, pure: [{kind: "stump"|"log", x, z, tree_x, tree_z, yaw,
## scale, model, length, radius}]. One candidate per tree record of a TREE family; the
## record's position hash decides whether it gets a piece and where (a couple
## of metres off, never on the trunk).
static func plan(bulks: Array, settings: Dictionary) -> Array:
	var out: Array = []
	var per := clampf(float(settings.get(KEY_DENSITY, 0.0)), 0.0, 100.0) / 100.0
	if per <= 0.0:
		return out
	var log_share := clampf(float(settings.get(KEY_LOG_SHARE, 0.5)), 0.0, 1.0)
	var models := stump_models(settings)
	if models.is_empty():
		log_share = 1.0
	for bulk in bulks:
		if not (bulk is Dictionary):
			continue
		for slot in (bulk as Dictionary):
			var fam := VegSpeciesCatalog.mesh_family(str(slot))
			if fam != "pine" and fam != "deciduous":
				continue
			for item in (bulk as Dictionary)[slot]:
				if not (item is Dictionary):
					continue
				var d: Dictionary = item
				var tx := float(d.get("x", 0.0))
				var tz := float(d.get("z", 0.0))
				if hash01(tx, tz, 1.0) >= per:
					continue
				var ang := hash01(tx, tz, 2.0) * TAU
				var dist := 2.2 + hash01(tx, tz, 3.0) * 3.8
				var p := {
					"tree_x": tx,
					"tree_z": tz,
					"x": tx + cos(ang) * dist,
					"z": tz + sin(ang) * dist,
					"yaw": hash01(tx, tz, 4.0) * TAU,
				}
				if hash01(tx, tz, 5.0) < log_share:
					p["kind"] = "log"
					p["length"] = lerpf(4.0, 13.0, pow(hash01(tx, tz, 6.0), 1.4))
					p["radius"] = lerpf(0.18, 0.55, hash01(tx, tz, 7.0))
				else:
					p["kind"] = "stump"
					p["model"] = str(models[int(hash01(tx, tz, 8.0) * models.size()) % models.size()])
					p["scale"] = lerpf(0.75, 1.15, hash01(tx, tz, 9.0))
				out.append(p)
	return out


## The stump model ids. Stored as a comma-separated STRING: the style store
## reads any JSON array of 3+ numbers-or-not as a Color, so a list of three
## models would come back as one. An Array is accepted too (tests, callers).
static func stump_models(settings: Dictionary) -> Array:
	var raw: Variant = settings.get(KEY_MODELS, "")
	var out: Array = []
	if raw is Array:
		for v in raw:
			if not str(v).strip_edges().is_empty():
				out.append(str(v).strip_edges())
	elif raw is String:
		for v in (raw as String).split(",", false):
			if not v.strip_edges().is_empty():
				out.append(v.strip_edges())
	return out


## Rebuild the deadwood under `terrain` from the given layer bulks. Returns
## how many pieces were drawn. Always clears the previous build first.
## `excluded` (optional, Vector2 -> bool): roads, buildings and water — a
## piece whose spot is excluded is dropped (a log across the driveway).
static func rebuild(terrain: Node3D, bulks: Array, ground_y_at: Callable,
		settings: Dictionary, excluded: Callable = Callable()) -> int:
	clear(terrain)
	if terrain == null or not enabled(settings):
		return 0
	var items := plan(bulks, settings)
	if excluded.is_valid():
		var kept: Array = []
		for it in items:
			var d: Dictionary = it
			if not bool(excluded.call(Vector2(float(d["x"]), float(d["z"])))):
				kept.append(d)
		items = kept
	if items.is_empty():
		return 0
	var root := Node3D.new()
	root.name = ROOT_NAME
	terrain.add_child(root)
	var vis := maxf(float(settings.get(KEY_VIS, DEFAULT_VIS_M)), 30.0)
	# Bucket by (chunk, mesh key).
	var buckets: Dictionary = {}
	for it in items:
		var d: Dictionary = it
		var key := "log" if str(d["kind"]) == "log" else "s:" + str(d["model"])
		var ck := Vector2i(int(floor(float(d["x"]) / CHUNK_M)), int(floor(float(d["z"]) / CHUNK_M)))
		var bk := "%s|%d|%d" % [key, ck.x, ck.y]
		if not buckets.has(bk):
			buckets[bk] = {"key": key, "chunk": ck, "items": []}
		(buckets[bk]["items"] as Array).append(d)
	var drawn := 0
	for bk in buckets:
		var b: Dictionary = buckets[bk]
		if str(b["key"]) == "log":
			drawn += _build_logs(root, b["items"], ground_y_at, vis, b["chunk"])
		else:
			drawn += _build_stumps(root, str(b["key"]).substr(2), b["items"],
				ground_y_at, vis, b["chunk"])
	return drawn


static func clear(terrain: Node3D) -> void:
	if terrain == null:
		return
	var old := terrain.get_node_or_null(ROOT_NAME)
	if old != null:
		terrain.remove_child(old)
		old.queue_free()


# --- stumps -----------------------------------------------------------------

static func _build_stumps(root: Node3D, model_id: String, items: Array,
		ground_y_at: Callable, vis: float, chunk: Vector2i) -> int:
	var mesh := stump_mesh(model_id)
	if mesh == null:
		return 0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = items.size()
	var i := 0
	for it in items:
		var d: Dictionary = it
		var x := float(d["x"])
		var z := float(d["z"])
		var s := float(d.get("scale", 1.0))
		# Seat on the LOWEST ground under the footprint so the downhill side
		# never floats; the uphill side sinks into the slope like a real stump.
		var r := mesh.get_aabb().size.x * 0.35 * s
		var gy := float(ground_y_at.call(x, z))
		for o in [Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
			gy = minf(gy, float(ground_y_at.call(x + o.x, z + o.y)))
		var basis := Basis(Vector3.UP, float(d["yaw"])).scaled(Vector3.ONE * s)
		mm.set_instance_transform(i, Transform3D(basis, Vector3(x, gy - 0.08, z)))
		i += 1
	mm.instance_count = i
	var mi := MultiMeshInstance3D.new()
	mi.name = "Stumps_%s_%d_%d" % [model_id, chunk.x, chunk.y]
	mi.multimesh = mm
	# A textured model keeps its own bark and gets a moss pass on top; a
	# flat-painted one is redrawn as weathered wood (see _fit_stump).
	if not mesh.has_meta("deadwood_procedural"):
		mi.material_overlay = _moss_material()
	VegetationRuntime.apply_visibility_range(mi, 0.0, vis)
	root.add_child(mi)
	return i


## The stump model merged into one mesh: centred in XZ, foot at y = 0, in
## metres (fitted to the STUMP_MAX_* box when it is bigger). Cached per id.
static func stump_mesh(model_id: String) -> ArrayMesh:
	if _stump_cache.has(model_id):
		return _stump_cache[model_id]
	var mesh: ArrayMesh = null
	var scene := ModelCatalog.load_scene(model_id)
	if scene != null:
		var raw := BrcCampGenerator._merge_scene_mesh(scene)
		if raw != null:
			mesh = _fit_stump(raw)
	_stump_cache[model_id] = mesh
	return mesh


static func _fit_stump(raw: ArrayMesh) -> ArrayMesh:
	var box := raw.get_aabb()
	if box.size.y < 0.001:
		return null
	var s := 1.0
	if box.size.y < STUMP_SANE_H.x or box.size.y > STUMP_SANE_H.y:
		s = STUMP_FALLBACK_H_M / box.size.y
	var span := maxf(box.size.x, box.size.z) * s
	if span > STUMP_MAX_SPAN_M:
		s *= STUMP_MAX_SPAN_M / span
	if box.size.y * s > STUMP_MAX_H_M:
		s *= STUMP_MAX_H_M / (box.size.y * s)
	var centre := box.position + box.size * 0.5
	var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * s), Vector3.ZERO) \
		* Transform3D(Basis.IDENTITY, Vector3(-centre.x, -box.position.y, -centre.z))
	var out := ArrayMesh.new()
	var textured := false
	for si in raw.get_surface_count():
		var m := raw.surface_get_material(si)
		if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null:
			textured = true
	for si in raw.get_surface_count():
		var arr := raw.surface_get_arrays(si)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nv := PackedVector3Array()
		nv.resize(verts.size())
		for vi in verts.size():
			nv[vi] = xf * verts[vi]
		arr[Mesh.ARRAY_VERTEX] = nv
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var m := raw.surface_get_material(si)
		# Flat paint (no bark texture) reads as a pale plastic stump: draw
		# every surface as weathered, mossy wood instead.
		if not textured:
			m = _stump_material()
		if m != null:
			out.surface_set_material(si, m)
	if not textured:
		out.set_meta("deadwood_procedural", true)
	return out


# --- logs -------------------------------------------------------------------

static func _build_logs(root: Node3D, items: Array, ground_y_at: Callable,
		vis: float, chunk: Vector2i) -> int:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = log_mesh()
	mm.instance_count = items.size()
	var i := 0
	for it in items:
		var xf: Variant = log_transform(it, ground_y_at)
		if xf == null:
			continue
		var d: Dictionary = it
		mm.set_instance_transform(i, xf)
		mm.set_instance_custom_data(i, Color(float(d["length"]), float(d["radius"]),
			hash01(float(d["x"]), float(d["z"]), 11.0), 0.0))
		i += 1
	mm.instance_count = i
	if i == 0:
		return 0
	var mi := MultiMeshInstance3D.new()
	mi.name = "Logs_%d_%d" % [chunk.x, chunk.y]
	mi.multimesh = mm
	mi.material_override = _log_material()
	VegetationRuntime.apply_visibility_range(mi, 0.0, vis)
	root.add_child(mi)
	return i


## A log lies ALONG the ground: its axis runs between the ground under its two
## ends, half buried by a fifth of its radius. A slope steeper than ~35° along
## the log would make a ramp in the air — those logs are turned across the
## slope instead (a fallen trunk rolls until it lies along the contour).
## Returns null when no orientation works.
static func log_transform(d: Dictionary, ground_y_at: Callable) -> Variant:
	var x := float(d["x"])
	var z := float(d["z"])
	var length := float(d["length"])
	var radius := float(d["radius"])
	for turn in [0.0, PI * 0.5]:
		var yaw := float(d["yaw"]) + float(turn)
		var dir := Vector2(cos(yaw), sin(yaw))
		var half := dir * length * 0.5
		var y0 := float(ground_y_at.call(x - half.x, z - half.y))
		var y1 := float(ground_y_at.call(x + half.x, z + half.y))
		var ym := float(ground_y_at.call(x, z))
		var rise := y1 - y0
		if absf(rise) > length * 0.7:
			continue
		var axis := Vector3(dir.x * length, rise, dir.y * length).normalized()
		var up := Vector3.UP
		var side := axis.cross(up).normalized()
		up = side.cross(axis).normalized()
		# Mesh: unit cylinder along +X, radius 1 — scale it into place.
		var basis := Basis(axis * length, up * radius, side * radius)
		# The mid-ground can bulge above the chord (a log over a hump): sit on
		# whichever is higher so the middle never sinks out of sight.
		var cy := maxf((y0 + y1) * 0.5, ym - radius * 0.3) + radius * 0.8
		return Transform3D(basis, Vector3(x, cy, z))
	return null


## Unit log: a 10-sided cylinder along +X from -0.5 to 0.5, radius 1, with
## end caps. UV.x runs 0..1 along the length, UV.y 0..1 round it; the caps
## carry UV2 = (1, r) so the shader can draw the cut face's rings.
static func log_mesh() -> ArrayMesh:
	if _log_mesh != null:
		return _log_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 10
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var n0 := Vector3(0.0, cos(a0), sin(a0))
		var n1 := Vector3(0.0, cos(a1), sin(a1))
		var v0 := float(i) / float(sides)
		var v1 := float(i + 1) / float(sides)
		var quad := [
			[Vector3(-0.5, n0.y, n0.z), n0, Vector2(0.0, v0)],
			[Vector3(0.5, n0.y, n0.z), n0, Vector2(1.0, v0)],
			[Vector3(0.5, n1.y, n1.z), n1, Vector2(1.0, v1)],
			[Vector3(-0.5, n1.y, n1.z), n1, Vector2(0.0, v1)],
		]
		for idx in [0, 2, 1, 0, 3, 2]:
			var q: Array = quad[idx]
			st.set_normal(q[1])
			st.set_uv(q[2])
			st.set_uv2(Vector2(0.0, 0.0))
			st.add_vertex(q[0])
		# Caps (fans): +X and -X.
		for e in [0.5, -0.5]:
			var n := Vector3(signf(e), 0.0, 0.0)
			var tri := [Vector3(e, 0.0, 0.0), Vector3(e, n0.y, n0.z), Vector3(e, n1.y, n1.z)]
			var order := [0, 1, 2] if e > 0.0 else [0, 2, 1]
			for k in order:
				var p: Vector3 = tri[k]
				st.set_normal(n)
				st.set_uv(Vector2(0.5 + e, 0.0))
				st.set_uv2(Vector2(1.0, Vector2(p.y, p.z).length()))
				st.add_vertex(p)
	_log_mesh = st.commit()
	return _log_mesh


static func _log_material() -> ShaderMaterial:
	if _log_mat == null:
		_log_mat = ShaderMaterial.new()
		_log_mat.shader = LOG_SHADER
	return _log_mat


static func _stump_material() -> ShaderMaterial:
	if _stump_mat == null:
		_stump_mat = ShaderMaterial.new()
		_stump_mat.shader = STUMP_SHADER
	return _stump_mat


static func _moss_material() -> ShaderMaterial:
	if _moss_mat == null:
		_moss_mat = ShaderMaterial.new()
		_moss_mat.shader = MOSS_SHADER
	return _moss_mat

class_name CampAreaRuntime
extends Node3D

## Scene side of painted camps: one child node per camp area, so an edit
## rebuilds only the camp it touched and each camp frustum-culls on its own.
##
##   PaintedCamps (this)
##     Area_<id>/Class_<cls>_MM        textured GLB (or the tinted shape), near
##     Area_<id>/Class_<cls>_Far_MM    tinted proxy beyond the art range
##     CampGlow_MM                     every camp's night lights, one batch
##     CampLightPool                   real OmniLights near the camera
##
## The node is named "PaintedCamps" on purpose: TerrainLoader's legacy
## `_remove_existing_camps()` frees every Terrain child whose name BEGINS WITH
## "Camps", which would otherwise delete the player's painted work every time
## the street-following generator re-ran.
##
## Visibility ranges are set at BUILD time only — sweeping visibility_range on
## live nodes hard-crashed the AMD Vulkan driver (see VegetationRuntime).

const NODE_NAME := "PaintedCamps"
const GLOW_SHADER := preload("res://vegetation/camp_glow.gdshader")
const CampLightPoolScript := preload("res://vegetation/camp_light_pool.gd")

## Textured art is drawn out to this far from the nearest structure of a batch.
const ART_RANGE_M := 220.0
## Nothing is drawn past this.
const FAR_RANGE_M := 1800.0
## Whole-map instance budget across every painted camp.
const MAX_TOTAL_STRUCTURES := 60000

var use_art := true
var _main: Node = null
var _glow_dirty := false
var _glow_mat: ShaderMaterial = null


func _init() -> void:
	name = NODE_NAME


func setup(main: Node, with_art: bool = true) -> void:
	_main = main
	use_art = with_art


## Rebuild every camp in the layer and drop nodes for camps that are gone.
func sync(layer: CampAreaLayer, ctx: Dictionary) -> void:
	var keep: Dictionary = {}
	if layer != null:
		for rec: Dictionary in layer.areas:
			keep[_area_node_name(str(rec["id"]))] = true
	for child in get_children():
		if String(child.name).begins_with("Area_") and not keep.has(String(child.name)):
			_free_now(child)
	if layer != null:
		for rec: Dictionary in layer.areas:
			rebuild_area(rec, ctx)
	_queue_glow_refresh()


## Rebuild one camp. Returns the generator's stats (plus "over_budget").
## `keep_items` (the Tune-look studio) also stores every placed element on the
## node as meta "items" — [{key, cls, pos, yaw, scale, size, edited}] — so a
## click in the preview can be resolved back to the element it hit.
func rebuild_area(area: Dictionary, ctx: Dictionary, keep_items: bool = false) -> Dictionary:
	var id := str(area.get("id", ""))
	_free_now(get_node_or_null(_area_node_name(id)))
	var result := CampLayoutGenerator.generate(area, ctx)
	var stats: Dictionary = result["stats"]
	var budget_left := MAX_TOTAL_STRUCTURES - structure_count()
	stats["over_budget"] = int(stats["structures"]) > budget_left
	var node := Node3D.new()
	node.name = _area_node_name(id)
	node.set_meta("area_id", id)
	node.set_meta("stats", stats)
	node.set_meta("glow", [] if stats["over_budget"] else result["glow"])
	node.set_meta("structures", 0 if stats["over_budget"] else int(stats["structures"]))
	add_child(node)
	if not stats["over_budget"]:
		var classes: Dictionary = result["classes"]
		var items: Array = []
		for cls in classes.keys():
			_build_class_batches(node, str(cls), classes[cls])
			if keep_items:
				items.append_array(classes[cls])
		if keep_items:
			node.set_meta("items", items)
	_queue_glow_refresh()
	return stats


func remove_area(id: String) -> void:
	_free_now(get_node_or_null(_area_node_name(id)))
	_queue_glow_refresh()


func clear_all() -> void:
	for child in get_children():
		if String(child.name).begins_with("Area_"):
			_free_now(child)
	_queue_glow_refresh()


func structure_count() -> int:
	var n := 0
	for child in get_children():
		n += int(child.get_meta("structures", 0))
	return n


func area_structure_count(id: String) -> int:
	var node := get_node_or_null(_area_node_name(id))
	return int(node.get_meta("structures", 0)) if node != null else 0


func area_stats(id: String) -> Dictionary:
	var node := get_node_or_null(_area_node_name(id))
	return node.get_meta("stats", {}) if node != null else {}


func area_items(id: String) -> Array:
	var node := get_node_or_null(_area_node_name(id))
	return node.get_meta("items", []) if node != null else []


func has_area(id: String) -> bool:
	return get_node_or_null(_area_node_name(id)) != null


## World transforms of one class in one camp (harness / selftest inspection).
func area_class_transforms(id: String, cls: String) -> Array:
	var out: Array = []
	var mmi := get_node_or_null("%s/Class_%s_MM" % [_area_node_name(id), cls]) as MultiMeshInstance3D
	if mmi == null or mmi.multimesh == null:
		return out
	for i in mmi.multimesh.instance_count:
		out.append(mmi.multimesh.get_instance_transform(i))
	return out


# ---------------------------------------------------------------------------

static func _area_node_name(id: String) -> String:
	return "Area_%s" % id


static func _free_now(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func _build_class_batches(parent: Node3D, cls: String, items: Array) -> void:
	if items.is_empty():
		return
	var meshes := CampMeshLibrary.class_meshes(cls, use_art)
	var xforms: Array = []
	var centre := Vector3.ZERO
	for c: Dictionary in items:
		var basis := Basis(Vector3.UP, float(c["yaw"]))
		var up: Vector3 = c.get("up", Vector3.UP)
		if up.distance_squared_to(Vector3.UP) > 1e-6:
			basis = Basis(Quaternion(Vector3.UP, up.normalized())) * basis
		xforms.append(Transform3D(basis.scaled(Vector3.ONE * float(c["scale"])), c["pos"]))
		centre += c["pos"]
	centre /= float(items.size())
	var radius := 0.0
	for c: Dictionary in items:
		radius = maxf(radius, (c["pos"] as Vector3).distance_to(centre))
	# Ranges are measured to the batch, not to each instance, so the art range
	# is padded by the batch's own radius: nothing within ART_RANGE_M of the
	# camera is ever drawn as a proxy.
	var art_end := ART_RANGE_M + radius
	var far_end := FAR_RANGE_M + radius
	var has_art := bool(meshes["has_art"])
	var near := _make_batch("Class_%s_MM" % cls, meshes["near"], meshes["near_material"],
		xforms, items)
	VegetationRuntime.apply_visibility_range(near, 0.0, art_end if has_art else far_end)
	parent.add_child(near)
	if has_art:
		var far := _make_batch("Class_%s_Far_MM" % cls, meshes["proxy"],
			CampMeshLibrary.tint_material(), xforms, items)
		far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		VegetationRuntime.apply_visibility_range(far, art_end, far_end)
		parent.add_child(far)


static func _make_batch(node_name: String, mesh: Mesh, material: Material,
		xforms: Array, items: Array) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, (items[i] as Dictionary)["color"])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	if material != null:
		mmi.material_override = material
	return mmi


# -- Night lights ------------------------------------------------------------

func _queue_glow_refresh() -> void:
	if _glow_dirty:
		return
	_glow_dirty = true
	if is_inside_tree():
		call_deferred("refresh_glow_now")


func _ready() -> void:
	if _glow_dirty:
		call_deferred("refresh_glow_now")


## One glow batch + one light pool for every painted camp. Coalesced: a brush
## stroke that touches three camps rebuilds this once.
func refresh_glow_now() -> void:
	_glow_dirty = false
	var glow: Array = []
	for child in get_children():
		glow.append_array(child.get_meta("glow", []))
	_free_now(get_node_or_null("CampGlow_MM"))
	var pool := get_node_or_null("CampLightPool")
	if glow.is_empty():
		_free_now(pool)
		return
	if _glow_mat == null:
		_glow_mat = ShaderMaterial.new()
		_glow_mat.shader = GLOW_SHADER
	var gmm := MultiMesh.new()
	gmm.transform_format = MultiMesh.TRANSFORM_3D
	gmm.use_colors = true
	gmm.mesh = BrcCampGenerator._glow_mesh()
	gmm.instance_count = glow.size()
	for i in glow.size():
		var g: Dictionary = glow[i]
		gmm.set_instance_transform(i, Transform3D(Basis.IDENTITY, g["pos"]))
		gmm.set_instance_color(i, g["color"])
	var gmmi := MultiMeshInstance3D.new()
	gmmi.name = "CampGlow_MM"
	gmmi.multimesh = gmm
	gmmi.material_override = _glow_mat
	gmmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gmmi)
	if pool == null:
		pool = CampLightPoolScript.new()
		pool.name = "CampLightPool"
		add_child(pool)
	pool.call("setup", glow, _glow_mat, _main)

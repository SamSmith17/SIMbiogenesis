class_name CampAreaRuntime
extends Node3D

## Scene side of painted camps: one child node per camp area, so an edit
## rebuilds only the camp it touched and each camp frustum-culls on its own.
##
##   PaintedCamps (this)
##     Area_<id>/Class_<cls>_MM        textured GLB (or the tinted shape), near
##     Area_<id>/Class_<cls>_Far_MM    tinted proxy beyond the art range
##     CampGlow_MM                     every camp's night lights, one batch
##     CampLightSpill_MM               their light on the ground, far views only
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
const SPILL_SHADER := preload("res://vegetation/camp_light_spill.gdshader")
const CampLightPoolScript := preload("res://vegetation/camp_light_pool.gd")

## Textured art is drawn out to this far from the nearest structure of a batch.
const ART_RANGE_M := 220.0
## Nothing is drawn past this.
const FAR_RANGE_M := 1800.0
## Whole-map instance budget across every painted camp.
const MAX_TOTAL_STRUCTURES := 60000

## Night-light look (camp_glow.gdshader + CampLightPool). A painted festival
## is a few thousand lights, not Black Rock City's 15 000, so it affords more
## real lights over a longer reach, faded by distance AND time.
const CARD_WORLD_SIZE_M := 0.3
const CARD_ANGULAR_SIZE := 0.0045
## Cards fade in over this distance band (m): inside it the real OmniLights
## carry the look and a card would only read as a floating orb.
const CARD_FADE_IN_M := Vector2(22.0, 75.0)
const POOL_LIGHTS := 64
const POOL_REACH_M := 200.0
const POOL_LIGHT_RANGE_M := 13.0
const POOL_ENERGY := 3.0
## Emissive-card peak at full night.
const CARD_INTENSITY := 18.0

var use_art := true
var _main: Node = null
var _glow_dirty := false
var _glow_mat: ShaderMaterial = null
var _spill_mat: ShaderMaterial = null
## How much of each camp STANDS, 0..1 (the site deployment schedule's crews
## pitch and strike camps household by household). Absent = 1. A rebuild
## reads the record's `built` flag; the director pushes the live fraction
## between the ends. Instances are revealed in each class batch's own order
## (the generator's cell order), and the shelters / shades / solids people
## use carry their index in that batch so they appear with their mesh.
var _built: Dictionary = {}


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
		# ALWAYS kept, compactly: where the shelters are (people sleep in
		# them) and which footprints are solid (people walk round them).
		var shelters: Array = []
		var solids: Array = []
		var shades: Array = []
		for cls in classes.keys():
			_build_class_batches(node, str(cls), classes[cls])
			if keep_items:
				items.append_array(classes[cls])
			var sleeps := int(CampStyles.SHELTER_SLEEPS.get(str(cls), 0))
			var solid := bool(CampStyles.SOLID_CLASSES.get(str(cls), false))
			var shade := bool(CampStyles.SHADE_CLASSES.get(str(cls), false))
			if sleeps <= 0 and not solid and not shade:
				continue
			var n_cls: int = (classes[cls] as Array).size()
			for ix in n_cls:
				var d: Dictionary = (classes[cls] as Array)[ix]
				var p: Vector3 = d.get("pos", Vector3.ZERO)
				var entry := {"pos": Vector2(p.x, p.z), "yaw": float(d.get("yaw", 0.0)),
					"size": d.get("size", Vector3.ONE), "cls": str(cls),
					"ix": ix, "n": n_cls}
				if sleeps > 0:
					entry["sleeps"] = sleeps
					shelters.append(entry)
				if solid:
					solids.append(entry)
				if shade:
					shades.append(entry)
		node.set_meta("shelters", shelters)
		node.set_meta("solids", solids)
		node.set_meta("shades", shades)
		if keep_items:
			node.set_meta("items", items)
	# The record's standing state wins on a rebuild; a live fraction the
	# director pushed is re-applied by its next push.
	_built[id] = 1.0 if bool(area.get("built", true)) else 0.0
	_apply_built(node, float(_built[id]))
	_queue_glow_refresh()
	return stats


## How much of camp `id` stands (0..1). Pushed live by the site deployment
## director while a crew pitches or strikes it; the record's `built` flag
## sets it on a rebuild. Cheap: visible_instance_count on the batches, the
## glow prefix, no mesh rebuild.
func set_built_fraction(id: String, f: float) -> void:
	var fr := clampf(f, 0.0, 1.0)
	var node := get_node_or_null(_area_node_name(id))
	if node == null:
		return
	if _built.has(id) and absf(float(_built[id]) - fr) < 1e-4:
		return
	_built[id] = fr
	_apply_built(node, fr)
	_queue_glow_refresh()


func built_fraction(id: String) -> float:
	return float(_built.get(id, 1.0))


## Instances revealed = ceil(f × n) per batch — the first household goes up
## as soon as the crew starts, the last with the last of the labour.
static func revealed_count(n: int, f: float) -> int:
	if f >= 1.0:
		return n
	if f <= 0.0:
		return 0
	return clampi(int(ceil(float(n) * f)), 0, n)


func _apply_built(node: Node, f: float) -> void:
	for child in node.get_children():
		var mmi := child as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null:
			continue
		var n := mmi.multimesh.instance_count
		mmi.multimesh.visible_instance_count = -1 if f >= 1.0 else revealed_count(n, f)
	# Lights follow the households: the glow list is in the generator's own
	# order, so its prefix lights the camps that stand.
	var glow_all: Array = node.get_meta("glow_all", node.get_meta("glow", []))
	node.set_meta("glow_all", glow_all)
	node.set_meta("glow", glow_all.slice(0, revealed_count(glow_all.size(), f)))


## An entry (shelter / shade / solid) stands when its index in its class
## batch is below the camp's revealed count.
func _standing(entry: Dictionary, f: float) -> bool:
	if f >= 1.0:
		return true
	return int(entry.get("ix", 0)) < revealed_count(int(entry.get("n", 1)), f)


func _standing_entries(meta_key: String) -> Array:
	var out: Array = []
	for child in get_children():
		if not String(child.name).begins_with("Area_"):
			continue
		var f := float(_built.get(str(child.get_meta("area_id", "")), 1.0))
		if f <= 0.0:
			continue
		for e in child.get_meta(meta_key, []):
			if _standing(e as Dictionary, f):
				out.append(e)
	return out


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


## Every STANDING shelter: [{pos: Vector2, yaw, size: Vector3, cls, sleeps}].
## A camp being pitched offers only the tents already up.
func all_shelters() -> Array:
	return _standing_entries("shelters")


## Every standing shade structure (canopies, tarps, shade arrays):
## [{pos, yaw, size, cls}].
func all_shades() -> Array:
	return _standing_entries("shades")


## Every standing solid (walk-round) footprint: [{pos, yaw, size, cls}].
func all_solids() -> Array:
	return _standing_entries("solids")


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
	_free_now(get_node_or_null("CampLightSpill_MM"))
	var pool := get_node_or_null("CampLightPool")
	if glow.is_empty():
		_free_now(pool)
		return
	if _glow_mat == null:
		_glow_mat = ShaderMaterial.new()
		_glow_mat.shader = GLOW_SHADER
		# Painted camps are a festival, not a 15 000-light city: smaller, more
		# numerous points, and NO card where the real lights already are — up
		# close you see what a light does to the canopy around it, not an orb.
		_glow_mat.set_shader_parameter("world_size", CARD_WORLD_SIZE_M)
		_glow_mat.set_shader_parameter("min_angular_size", CARD_ANGULAR_SIZE)
		_glow_mat.set_shader_parameter("near_fade_start", CARD_FADE_IN_M.x)
		_glow_mat.set_shader_parameter("near_fade_end", CARD_FADE_IN_M.y)
		_glow_mat.set_shader_parameter("twinkle_floor", 0.75)
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
	_build_spill(glow)
	if pool == null:
		pool = CampLightPoolScript.new()
		pool.name = "CampLightPool"
		pool.set("max_lights", POOL_LIGHTS)
		pool.set("cull_radius_m", POOL_REACH_M)
		pool.set("light_range_m", POOL_LIGHT_RANGE_M)
		pool.set("full_energy", POOL_ENERGY)
		pool.set("card_intensity", CARD_INTENSITY)
		add_child(pool)
	pool.call("setup", glow, _glow_mat, _main, [_spill_mat])


## The ground light around each household's main light, for views beyond the
## real lights' reach (see camp_light_spill.gdshader). The fade band is the
## pool's own fade-out band, so the two hand over invisibly.
func _build_spill(glow: Array) -> void:
	var spills: Array = []
	for g: Dictionary in glow:
		if g.has("spill_m"):
			spills.append(g)
	if spills.is_empty():
		return
	if _spill_mat == null:
		_spill_mat = ShaderMaterial.new()
		_spill_mat.shader = SPILL_SHADER
		_spill_mat.set_shader_parameter("fade_in_m",
			Vector2(POOL_REACH_M * 0.45, POOL_REACH_M))
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = plane
	mm.instance_count = spills.size()
	for i in spills.size():
		var g: Dictionary = spills[i]
		var p: Vector3 = g["pos"]
		var d := float(g["spill_m"]) * 2.0
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3(d, 1.0, d)),
			Vector3(p.x, float(g["ground_y"]) + 0.25, p.z)))
		mm.set_instance_color(i, g["color"])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "CampLightSpill_MM"
	mmi.multimesh = mm
	mmi.material_override = _spill_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

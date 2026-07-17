class_name GrowBed
extends Node3D

## Raised grow bed with lettuce that scales seed→full over ~90 sim days.
## Placed as a PlacedProp ModelRoot via ModelCatalog (`MODEL_ID`); growth is
## driven by CelestialClock absolute hours on Main.

const MODEL_ID := "grow_bed"
const LETTUCE_SPECIES := "lettuce"
const DEFAULT_GROW_DAYS := 90.0
const BED_SIZE := Vector3(1.2, 0.18, 0.8)
const PLANT_COUNT := 6

@export var grow_days: float = DEFAULT_GROW_DAYS
@export var senescence_days: float = 15.0
## Absolute hours when this bed was planted (growth clock / main abs hours).
var plant_abs_h: float = -1.0

var _plants: Array[Node3D] = []
var _main: Node = null


## Procedural catalog entry — used by ModelCatalog.instantiate / ghost placement.
static func build_node(spec: Dictionary = {}, node_name: String = "GrowBed") -> GrowBed:
	var bed := GrowBed.new()
	bed.name = node_name
	if spec.has("grow_days"):
		bed.grow_days = float(spec["grow_days"])
	if spec.has("senescence_days"):
		bed.senescence_days = float(spec["senescence_days"])
	if spec.has("plant_abs_h"):
		bed.plant_abs_h = float(spec["plant_abs_h"])
	bed._build_visuals()
	return bed


## Legacy helper (tests / tools). Prefer library → Place in world.
static func spawn_near_player(parent: Node3D, main: Node, offset := Vector3(2.5, 0.0, 1.5)) -> GrowBed:
	var bed := build_node({})
	parent.add_child(bed)
	bed._main = main
	var player: Node3D = null
	if main != null and main.get_tree() != null:
		player = main.get_tree().get_first_node_in_group("player") as Node3D
	var origin := Vector3.ZERO
	if player != null:
		origin = player.global_position + player.global_transform.basis * offset
	else:
		origin = offset
	bed.global_position = origin
	if main != null and main.has_method("get_absolute_hours"):
		bed.plant_abs_h = float(main.call("get_absolute_hours"))
	else:
		bed.plant_abs_h = 0.0
	bed._update_plant_scales()
	return bed


func configure_from_record(rec: Dictionary) -> void:
	if rec.has("grow_days"):
		grow_days = float(rec["grow_days"])
	if rec.has("senescence_days"):
		senescence_days = float(rec["senescence_days"])
	if rec.has("plant_abs_h"):
		plant_abs_h = float(rec["plant_abs_h"])
	var specs: Variant = rec.get("grow_bed_specs", {})
	if specs is Dictionary:
		var s := specs as Dictionary
		if s.has("grow_days"):
			grow_days = float(s["grow_days"])
		if s.has("senescence_days"):
			senescence_days = float(s["senescence_days"])


func _ready() -> void:
	if _main == null:
		_main = _find_main()
	if plant_abs_h < 0.0:
		if _main != null and _main.has_method("get_absolute_hours"):
			plant_abs_h = float(_main.call("get_absolute_hours"))
		else:
			plant_abs_h = 0.0
	if _plants.is_empty():
		_build_visuals()


func _process(_delta: float) -> void:
	_update_plant_scales()


func _build_visuals() -> void:
	for c in get_children():
		c.queue_free()
	_plants.clear()

	# Simple box frame for the raised bed.
	var frame := MeshInstance3D.new()
	frame.name = "BedFrame"
	var box := BoxMesh.new()
	box.size = BED_SIZE
	frame.mesh = box
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.42, 0.28, 0.14)
	frame.material_override = wood
	frame.position = Vector3(0.0, BED_SIZE.y * 0.5, 0.0)
	add_child(frame)

	var soil := MeshInstance3D.new()
	soil.name = "Soil"
	var soil_box := BoxMesh.new()
	soil_box.size = Vector3(BED_SIZE.x - 0.08, 0.06, BED_SIZE.z - 0.08)
	soil.mesh = soil_box
	var soil_mat := StandardMaterial3D.new()
	soil_mat.albedo_color = Color(0.22, 0.14, 0.08)
	soil.material_override = soil_mat
	soil.position = Vector3(0.0, BED_SIZE.y - 0.02, 0.0)
	add_child(soil)

	var settings := {
		"lettuce_growth_days": grow_days,
		"lettuce_senescence_days": senescence_days,
		"grass_field_card_w": 0.45,
		"grass_field_card_h": 0.28,
	}
	var mesh := VegetationCardFactory.mesh_for_species(LETTUCE_SPECIES, settings)
	var mat := VegetationCardFactory.material_for_species(LETTUCE_SPECIES, settings)
	var cols := 3
	var rows := 2
	var i := 0
	for r in rows:
		for c in cols:
			if i >= PLANT_COUNT:
				break
			var mi := MeshInstance3D.new()
			mi.name = "Lettuce_%d" % i
			mi.mesh = mesh
			mi.material_override = mat
			var fx := (float(c) / float(cols - 1) - 0.5) * (BED_SIZE.x * 0.55)
			var fz := (float(r) / float(rows - 1) - 0.5) * (BED_SIZE.z * 0.55)
			mi.position = Vector3(fx, BED_SIZE.y, fz)
			mi.scale = Vector3.ONE * VegetationGrowth.SEEDLING_SCALE
			add_child(mi)
			_plants.append(mi)
			i += 1
	_update_plant_scales()


func _update_plant_scales() -> void:
	if _plants.is_empty():
		return
	var now_h := plant_abs_h
	if _main == null:
		_main = _find_main()
	if _main != null and _main.has_method("get_absolute_hours"):
		now_h = float(_main.call("get_absolute_hours"))
	var age_h := maxf(now_h - plant_abs_h, 0.0)
	var grow_h := grow_days * VegetationGrowth.HOURS_PER_DAY
	var sen_h := senescence_days * VegetationGrowth.HOURS_PER_DAY
	var sc := VegetationGrowth.scale_for_lifecycle(age_h, grow_h, sen_h)
	for mi in _plants:
		if is_instance_valid(mi):
			mi.scale = Vector3.ONE * sc


func current_scale() -> float:
	var now_h := plant_abs_h
	if _main != null and _main.has_method("get_absolute_hours"):
		now_h = float(_main.call("get_absolute_hours"))
	var age_h := maxf(now_h - plant_abs_h, 0.0)
	return VegetationGrowth.scale_for_lifecycle(
		age_h, grow_days * VegetationGrowth.HOURS_PER_DAY,
		senescence_days * VegetationGrowth.HOURS_PER_DAY)


func current_stage() -> String:
	var now_h := plant_abs_h
	if _main != null and _main.has_method("get_absolute_hours"):
		now_h = float(_main.call("get_absolute_hours"))
	var age_h := maxf(now_h - plant_abs_h, 0.0)
	return VegetationGrowth.growth_stage(
		age_h, grow_days * VegetationGrowth.HOURS_PER_DAY,
		senescence_days * VegetationGrowth.HOURS_PER_DAY)


func _find_main() -> Node:
	if not is_inside_tree():
		return null
	var n: Node = self
	while n != null:
		if "day_time" in n and n.has_method("get_absolute_hours"):
			return n
		n = n.get_parent()
	return get_tree().current_scene

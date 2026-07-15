class_name PlacedLightRuntime
extends RefCounted

## Builds PlacedLight nodes under Terrain/PlacedLights.

static func add_one(terrain: Node3D, rec: Dictionary) -> PlacedLight:
	if terrain == null:
		return null
	var root := terrain.get_node_or_null("PlacedLights") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "PlacedLights"
		terrain.add_child(root)
	return _build_light(rec, root)

static func rebuild(terrain: Node3D, layer: PlacedLightLayer) -> void:
	if terrain == null or layer == null:
		return
	var root := terrain.get_node_or_null("PlacedLights") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "PlacedLights"
		terrain.add_child(root)
	for child in root.get_children():
		child.queue_free()
	for rec in layer.lights:
		_build_light(rec as Dictionary, root)

static func find_by_id(main: Node, id: String) -> PlacedLight:
	if main == null or id.is_empty():
		return null
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = main.find_child("Terrain", true, false)
	if terrain == null:
		return null
	var root := terrain.get_node_or_null("PlacedLights")
	if root == null:
		return null
	for child in root.get_children():
		if child is PlacedLight and str((child as PlacedLight).light_id) == id:
			return child as PlacedLight
	return null

static func _build_light(rec: Dictionary, parent: Node3D) -> PlacedLight:
	var light := PlacedLight.new()
	light.name = "PlacedLight_%s" % str(rec.get("id", "unknown"))
	light.light_id = str(rec.get("id", ""))
	
	apply_record_to_light(light, rec)
	parent.add_child(light)
	return light

static func apply_record_to_light(light: PlacedLight, rec: Dictionary) -> void:
	var x := float(rec.get("x", 0.0))
	var y := float(rec.get("y", 0.0))
	var z := float(rec.get("z", 0.0))
	var yaw := float(rec.get("yaw", 0.0))
	var pitch := float(rec.get("pitch", 0.0))
	var roll := float(rec.get("roll", 0.0))
	
	light.position = Vector3(x, y, z)
	light.rotation = Vector3(pitch, yaw, roll)
	
	light.light_type = str(rec.get("type", "omni"))
	light.light_color = Color(str(rec.get("color", "ffffff")))
	light.light_energy = float(rec.get("energy", 1.0))
	light.light_range = float(rec.get("range", 10.0))
	light.spot_angle = float(rec.get("spot_angle", 45.0))
	
	light.update_light_node()

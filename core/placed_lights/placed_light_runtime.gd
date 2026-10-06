class_name PlacedLightRuntime
extends RefCounted

## Builds PlacedLight / PlacedStringLight nodes under Main/PlacedLights.
##
## Every node is top_level with a WORLD transform, so the parent no longer
## matters. (v2 parented under Terrain and applied the saved world hit point
## as a LOCAL position, which was only right while Terrain sat at the origin.)
## Parenting under Main rather than Terrain is what lets the built-in SOAK /
## Mars scenes — which have no TerrainLoader — show their lights at all.

const ROOT_NAME := "PlacedLights"


static func root_for(main: Node) -> Node3D:
	if main == null:
		return null
	var root := main.get_node_or_null(ROOT_NAME) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = ROOT_NAME
		main.add_child(root)
	return root


static func rebuild(main: Node, layer: PlacedLightLayer) -> void:
	var root := root_for(main)
	if root == null or layer == null:
		return
	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()
	for rec in layer.lights:
		if rec is Dictionary:
			build_one(main, layer, rec as Dictionary)


static func build_one(main: Node, layer: PlacedLightLayer, rec: Dictionary) -> Node3D:
	var root := root_for(main)
	if root == null or rec.is_empty():
		return null
	var id := str(rec.get("id", ""))
	var old := find_node(main, id)
	if old != null:
		root.remove_child(old)
		old.queue_free()
	var node: Node3D
	match str(rec.get("kind", "omni")):
		"string":
			node = PlacedStringLight.new()
		"mover":
			node = PlacedMoverLight.new()
		_:
			node = PlacedLight.new()
	node.name = "L_%s" % id
	root.add_child(node)
	apply(main, layer, node, rec)
	return node


## Push the record onto its node (rebuilding only what changed).
static func apply(main: Node, layer: PlacedLightLayer, node: Node3D, rec: Dictionary) -> void:
	var res := layer.resolved(rec)
	node.visible = not layer.is_hidden_by_group(rec)
	if node is PlacedStringLight:
		(node as PlacedStringLight).configure(rec, res, main)
	elif node is PlacedLight:
		(node as PlacedLight).configure(rec, res)


static func find_node(main: Node, id: String) -> Node3D:
	if main == null or id.is_empty():
		return null
	var root := main.get_node_or_null(ROOT_NAME)
	if root == null:
		return null
	return root.get_node_or_null("L_%s" % id) as Node3D


static func remove_node(main: Node, id: String) -> void:
	var n := find_node(main, id)
	if n != null:
		n.get_parent().remove_child(n)
		n.queue_free()

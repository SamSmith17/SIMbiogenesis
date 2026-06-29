class_name VegetationUndo
extends RefCounted

## Lightweight undo stack for manual vegetation bulk + auto-veg edit snapshots.

const MAX_DEPTH := 24

var _stack: Array = []


func clear() -> void:
	_stack.clear()


func can_undo() -> bool:
	return not _stack.is_empty()


func push_combined(manual_bulk: Dictionary, auto_edits: AutoVegetationEdits,
		label: String = "") -> void:
	var snap := {
		"type": "combined",
		"label": label,
		"bulk": _dup_bulk(manual_bulk),
	}
	if auto_edits != null:
		snap["auto_edits"] = auto_edits.serialize()
	_push(snap)


func pop() -> Dictionary:
	if _stack.is_empty():
		return {}
	return _stack.pop_back() as Dictionary


static func _dup_bulk(src: Dictionary) -> Dictionary:
	var out := {}
	for species in VegetationLayer.ALL_SPECIES:
		var arr: Array = []
		for item in src.get(species, []):
			if item is Dictionary:
				arr.append((item as Dictionary).duplicate(true))
		out[species] = arr
	return out


static func restore_manual_bulk(layer: VegetationLayer, snap: Dictionary) -> void:
	if layer == null or not snap.has("bulk"):
		return
	var bulk: Dictionary = snap["bulk"]
	for species in VegetationLayer.ALL_SPECIES:
		layer.bulk[species] = bulk.get(species, []).duplicate(true)


static func restore_auto_edits(edits: AutoVegetationEdits, data: Dictionary) -> void:
	if edits == null or data.is_empty():
		return
	edits.deserialize(data)


func _push(snap: Dictionary) -> void:
	_stack.append(snap)
	while _stack.size() > MAX_DEPTH:
		_stack.pop_front()

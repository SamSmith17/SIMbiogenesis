class_name VegetationInstanceMap
extends RefCounted

## Maps bulk vegetation records to live MultiMesh instance slots for in-place
## growth-scale updates without a full rebuild (Phase 2 climelapse perf path).

var _entries: Array = []
var _cursor := 0

func clear() -> void:
	_entries.clear()
	_cursor = 0




## Growth multiplier for bake entry `index` at the given settings (no base_scale).
func scale_mult_at(index: int, settings: Dictionary) -> float:
	if index < 0 or index >= _entries.size():
		return 1.0
	var e: Dictionary = _entries[index]
	var species: String = str(e.get("species", ""))
	var record: Dictionary = e.get("record", {})
	return VegetationGrowth.instance_scale_mult(species, record, settings)


func is_empty() -> bool:
	return _entries.is_empty()


func entry_count() -> int:
	return _entries.size()


func reset_cursor() -> void:
	_cursor = 0


## Register one MultiMesh slot. `base_scale` is the draw scale BEFORE the growth
## multiplier (record.scale × species bulk scale, matching rebuild paths).
func add(mmi: MultiMeshInstance3D, idx: int, record: Dictionary, species: String,
		base_scale: float, vert_off: float, foot_y: float, align_to_surface: bool,
		x: float, z: float, yaw: float, ground_y: float = NAN) -> void:
	if mmi == null or record.is_empty():
		return
	_entries.append({
		"mmi": mmi,
		"idx": idx,
		"record": record,
		"species": species,
		"base_scale": base_scale,
		"vert_off": vert_off,
		"foot_y": foot_y,
		"align": align_to_surface,
		"x": x,
		"z": z,
		"yaw": yaw,
		"ground_y": ground_y,
	})


## Update transforms from the growth clock. `budget` < 0 applies all remaining
## entries; `budget` > 0 applies at most that many. Returns remaining budget
## (0 if exhausted mid-pass, unchanged if budget < 0). Resets cursor to 0 when
## the full map has been updated.
func apply_scales(settings: Dictionary, ground_y_at: Callable, budget: int) -> int:
	var rem := budget
	while _cursor < _entries.size():
		if rem == 0:
			break
		var e: Dictionary = _entries[_cursor]
		_cursor += 1
		var mmi: MultiMeshInstance3D = e.get("mmi")
		if mmi == null or not is_instance_valid(mmi):
			continue
		var mm: MultiMesh = mmi.multimesh
		if mm == null:
			continue
		var species: String = str(e.get("species", ""))
		var record: Dictionary = e.get("record", {})
		var scale: float = float(e.get("base_scale", 1.0)) \
			* VegetationGrowth.instance_scale_mult(species, record, settings)
		var gy: float = float(ground_y_at.call(float(e.get("x", 0.0)), float(e.get("z", 0.0))))
		mm.set_instance_transform(int(e.get("idx", 0)), VegetationPaint.build_transform(
			float(e.get("x", 0.0)), gy, float(e.get("z", 0.0)), float(e.get("yaw", 0.0)),
			scale, bool(e.get("align", false)), Vector3.UP,
			float(e.get("vert_off", 0.0)), float(e.get("foot_y", 0.0))))
		if rem > 0:
			rem -= 1
	if _cursor >= _entries.size():
		_cursor = 0
	return rem

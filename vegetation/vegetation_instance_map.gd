class_name VegetationInstanceMap
extends RefCounted

## Maps bulk vegetation records to live MultiMesh instance slots for in-place
## growth-scale updates without a full rebuild (Phase 2 climelapse perf path).

var _entries: Array = []
var _cursor := 0
var _baked_scales := PackedFloat32Array()
var _bake_keyframe_count := 0
var _bake_entry_count := 0


func clear() -> void:
	_entries.clear()
	_cursor = 0
	clear_baked_scales()


func clear_baked_scales() -> void:
	_baked_scales = PackedFloat32Array()
	_bake_keyframe_count = 0
	_bake_entry_count = 0


func has_baked_scales() -> bool:
	return _bake_keyframe_count > 0 and _baked_scales.size() > 0 \
		and _bake_entry_count == _entries.size()


func set_baked_scales(scales: PackedFloat32Array, keyframe_count: int) -> void:
	_baked_scales = scales
	_bake_keyframe_count = keyframe_count
	_bake_entry_count = _entries.size()
	reset_cursor()


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


## O(1) per-instance scale lookup from a pre-baked climelapse snapshot (Phase 4).
## When `frustum_cam` is set, instances outside the camera frustum are skipped
## (safe for fixed-view export — off-screen trees keep their last transform).
func apply_baked_scales(keyframe_idx: int, ground_y_at: Callable, budget: int,
		frustum_cam: Camera3D = null) -> int:
	if not has_baked_scales():
		return budget
	var kf := clampi(keyframe_idx, 0, _bake_keyframe_count - 1)
	var rem := budget
	while _cursor < _entries.size():
		if rem == 0:
			break
		var entry_idx := _cursor
		var e: Dictionary = _entries[entry_idx]
		_cursor += 1
		var mmi: MultiMeshInstance3D = e.get("mmi")
		if mmi == null or not is_instance_valid(mmi):
			continue
		var mm: MultiMesh = mmi.multimesh
		if mm == null:
			continue
		var x := float(e.get("x", 0.0))
		var z := float(e.get("z", 0.0))
		var gy: float
		if e.has("ground_y") and not is_nan(float(e.get("ground_y"))):
			gy = float(e.get("ground_y"))
		else:
			gy = float(ground_y_at.call(x, z))
			e["ground_y"] = gy
		if frustum_cam != null and not _in_frustum(frustum_cam, x, gy, z):
			continue
		var mult := _baked_scales[kf * _bake_entry_count + entry_idx]
		var scale: float = float(e.get("base_scale", 1.0)) * mult
		mm.set_instance_transform(int(e.get("idx", 0)), VegetationPaint.build_transform(
			x, gy, z, float(e.get("yaw", 0.0)),
			scale, bool(e.get("align", false)), Vector3.UP,
			float(e.get("vert_off", 0.0)), float(e.get("foot_y", 0.0))))
		if rem > 0:
			rem -= 1
	if _cursor >= _entries.size():
		_cursor = 0
	return rem


static func _in_frustum(cam: Camera3D, x: float, gy: float, z: float) -> bool:
	if cam == null:
		return true
	var foot := Vector3(x, gy, z)
	if cam.is_position_in_frustum(foot):
		return true
	# Crown sample so tall trees on the frame edge are not skipped.
	return cam.is_position_in_frustum(Vector3(x, gy + 14.0, z))

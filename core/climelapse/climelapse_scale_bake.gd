class_name ClimelapseScaleBake
extends RefCounted

## Per-instance growth scale multipliers at each climelapse keyframe (Phase 4).
## Layout: scales[keyframe_index * entry_count + entry_index] = multiplier.

const MAGIC := "CLSB"
const FILE_VERSION := 1

var manual_scales := PackedFloat32Array()
var auto_scales := PackedFloat32Array()
var manual_entry_count := 0
var auto_entry_count := 0
var keyframe_count := 0


func clear() -> void:
	manual_scales = PackedFloat32Array()
	auto_scales = PackedFloat32Array()
	manual_entry_count = 0
	auto_entry_count = 0
	keyframe_count = 0


func is_empty() -> bool:
	return keyframe_count <= 0 or (manual_scales.is_empty() and auto_scales.is_empty())


func has_manual() -> bool:
	return manual_entry_count > 0 and manual_scales.size() > 0


func has_auto() -> bool:
	return auto_entry_count > 0 and auto_scales.size() > 0


## Snapshot scale multipliers from live instance maps × series keyframes.
func bake_from_maps(manual_map: VegetationInstanceMap, auto_map: VegetationInstanceMap,
		series: ClimelapseSeries, growth_settings: Dictionary) -> void:
	clear()
	if series == null or series.keyframe_count() <= 0:
		return
	keyframe_count = series.keyframe_count()
	manual_entry_count = manual_map.entry_count() if manual_map != null else 0
	auto_entry_count = auto_map.entry_count() if auto_map != null else 0
	if manual_entry_count > 0:
		manual_scales.resize(manual_entry_count * keyframe_count)
	if auto_entry_count > 0:
		auto_scales.resize(auto_entry_count * keyframe_count)
	var st := growth_settings.duplicate(true)
	for k in keyframe_count:
		st["growth_now_h"] = series.growth_clock_at(k)
		if manual_entry_count > 0:
			for i in manual_entry_count:
				manual_scales[k * manual_entry_count + i] = manual_map.scale_mult_at(i, st)
		if auto_entry_count > 0:
			for i in auto_entry_count:
				auto_scales[k * auto_entry_count + i] = auto_map.scale_mult_at(i, st)


func save_layer(path: String, scales: PackedFloat32Array, entry_count: int) -> bool:
	if entry_count <= 0 or scales.is_empty():
		return true
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(MAGIC.to_utf8_buffer())
	f.store_32(FILE_VERSION)
	f.store_32(entry_count)
	f.store_32(keyframe_count)
	for i in scales.size():
		f.store_float(scales[i])
	return true


static func load_layer(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var magic := f.get_buffer(4).get_string_from_ascii()
	if magic != MAGIC:
		return {}
	var ver := f.get_32()
	if ver != FILE_VERSION:
		return {}
	var entry_count := int(f.get_32())
	var kf_count := int(f.get_32())
	var expected := entry_count * kf_count
	var scales := PackedFloat32Array()
	scales.resize(expected)
	for i in expected:
		if f.eof_reached():
			return {}
		scales[i] = f.get_float()
	return {
		"entry_count": entry_count,
		"keyframe_count": kf_count,
		"scales": scales,
	}


func save_to_dir(dir: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var meta := {
		"manual_entry_count": manual_entry_count,
		"auto_entry_count": auto_entry_count,
		"keyframe_count": keyframe_count,
	}
	if has_manual():
		var p := dir.path_join("manual_scales.bin")
		save_layer(p, manual_scales, manual_entry_count)
		meta["manual_scales"] = "manual_scales.bin"
	if has_auto():
		var p2 := dir.path_join("auto_scales.bin")
		save_layer(p2, auto_scales, auto_entry_count)
		meta["auto_scales"] = "auto_scales.bin"
	return meta


func load_from_dir(dir: String, meta: Dictionary) -> bool:
	clear()
	keyframe_count = int(meta.get("keyframe_count", 0))
	manual_entry_count = int(meta.get("manual_entry_count", 0))
	auto_entry_count = int(meta.get("auto_entry_count", 0))
	var mp := str(meta.get("manual_scales", ""))
	if not mp.is_empty() and manual_entry_count > 0:
		var md: Dictionary = load_layer(dir.path_join(mp))
		if md.is_empty():
			return false
		manual_scales = md.get("scales", PackedFloat32Array())
	var ap := str(meta.get("auto_scales", ""))
	if not ap.is_empty() and auto_entry_count > 0:
		var ad: Dictionary = load_layer(dir.path_join(ap))
		if ad.is_empty():
			return false
		auto_scales = ad.get("scales", PackedFloat32Array())
	return keyframe_count > 0

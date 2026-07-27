class_name MachineJobStore
extends RefCounted

## Persists a parsed+decimated machine job (the toolpath the 3D machine traces
## plus its bounds/summary) as user://machines/jobs/<job_id>.json, so the heavy
## point path lives OUT of the graph autosave JSON. The graph node only stores a
## compact job_id + scalar summary; the 3D CncMachineRuntime loads the path by id
## to animate. Points are flattened to a float array for compactness.

const JOBS_DIR := "user://machines/jobs"


static func save(parse: Dictionary) -> String:
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
	if pts.is_empty():
		return ""
	var job_id := "job_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOBS_DIR))
	var flat := PackedFloat32Array()
	flat.resize(pts.size() * 3)
	for i in pts.size():
		flat[i * 3] = pts[i].x
		flat[i * 3 + 1] = pts[i].y
		flat[i * 3 + 2] = pts[i].z
	var ext: PackedInt32Array = parse.get("extruding", PackedInt32Array())
	var bmin: Vector3 = parse.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = parse.get("bounds_max", Vector3.ZERO)
	var data := {
		"version": 1,
		"kind": str(parse.get("kind", "")),
		"pts": Array(flat),
		"ext": Array(ext),
		"bmin": [bmin.x, bmin.y, bmin.z],
		"bmax": [bmax.x, bmax.y, bmax.z],
	}
	var f := FileAccess.open("%s/%s.json" % [JOBS_DIR, job_id], FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(data))
	return job_id


static func load(job_id: String) -> Dictionary:
	if job_id.is_empty():
		return {}
	var path := "%s/%s.json" % [JOBS_DIR, job_id]
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return {}
	var d := parsed as Dictionary
	var flat: Array = d.get("pts", [])
	var pts := PackedVector3Array()
	var count := int(flat.size() / 3)
	pts.resize(count)
	for i in count:
		pts[i] = Vector3(float(flat[i * 3]), float(flat[i * 3 + 1]), float(flat[i * 3 + 2]))
	var bmin_a: Array = d.get("bmin", [0, 0, 0])
	var bmax_a: Array = d.get("bmax", [0, 0, 0])
	var ext_a: Array = d.get("ext", [])
	var ext := PackedInt32Array()
	ext.resize(ext_a.size())
	for i in ext_a.size():
		ext[i] = int(ext_a[i])
	return {
		"points": pts,
		"extruding": ext,
		"bounds_min": Vector3(float(bmin_a[0]), float(bmin_a[1]), float(bmin_a[2])),
		"bounds_max": Vector3(float(bmax_a[0]), float(bmax_a[1]), float(bmax_a[2])),
		"kind": str(d.get("kind", "")),
	}

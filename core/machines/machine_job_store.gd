class_name MachineJobStore
extends RefCounted

## Persists a machine job out of the graph autosave JSON: the graph node
## keeps a compact job_id + scalar summary, the 3D runtime loads the path by
## id. Two layouts:
##   v2 (`<job_id>.job`, binary via store_var): the MOVE LIST a planner runs
##      — p0 / p1 / feed / e_mm / rapid per move — plus the machine's limits
##      and the road size, so the in-world machine replays the planned
##      motion exactly. Written for any job that carries `moves`.
##   v1 (`<job_id>.json`): points + extruding flags (the old decimated
##      toolpath). Still read; PrintJobPlayer turns one into moves.

const JOBS_DIR := "user://machines/jobs"
const VERSION := 2


static func save(parse: Dictionary) -> String:
	var job_id := "job_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOBS_DIR))
	if PrintMoves.count(parse.get("moves", [])) > 0:
		return job_id if _save_v2(job_id, parse) else ""
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
	if pts.is_empty():
		return ""
	return job_id if _save_v1(job_id, parse) else ""


static func _save_v2(job_id: String, job: Dictionary) -> bool:
	var pm := PrintMoves.from_any(job["moves"])
	var n := pm.size()
	var a := pm.p0
	var b := pm.p1
	var f := pm.feed
	var e := pm.e
	var r := pm.rapid
	var limits: Dictionary = (job.get("limits", {}) as Dictionary).duplicate()
	limits.erase("spec")
	var data := {
		"version": VERSION,
		"kind": str(job.get("kind", "")),
		"name": str(job.get("name", "")),
		"n": n, "a": a, "b": b, "f": f, "e": e, "r": r,
		"bmin": job.get("bounds_min", Vector3.ZERO),
		"bmax": job.get("bounds_max", Vector3.ZERO),
		"limits": limits,
		"line_width_mm": float(job.get("line_width_mm", 0.4)),
		"layer_height_mm": float(job.get("layer_height_mm", 0.2)),
		"filament_mm": float(job.get("filament_mm", 1.75)),
		"extrusion_mm": float(job.get("extrusion_mm", 0.0)),
		"volume_mm3": float(job.get("volume_mm3", 0.0)),
		"additive": bool(job.get("additive", true)),
		"total_s": float(job.get("total_s", 0.0)),
		"layers": int(job.get("layers", 0)),
		"layer_starts": job.get("layer_starts", PackedInt32Array()),
		"layer_z": job.get("layer_z", PackedFloat32Array()),
		"mode": str(job.get("mode", "")),
	}
	# The plan rides along (its packed arrays, not the moves twice): a
	# million-move job re-planned on load stalled the world for seconds.
	var plan: Dictionary = job.get("plan", {})
	if int(plan.get("n", 0)) == n:
		var pd := plan.duplicate()
		pd.erase("moves")
		pd.erase("pm")
		data["plan"] = pd
	var fh := FileAccess.open("%s/%s.job" % [JOBS_DIR, job_id], FileAccess.WRITE)
	if fh == null:
		return false
	fh.store_var(data, false)
	fh.close()
	return true


static func _save_v1(job_id: String, parse: Dictionary) -> bool:
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
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
		return false
	f.store_string(JSON.stringify(data))
	return true


static func exists(job_id: String) -> bool:
	if job_id.is_empty():
		return false
	return FileAccess.file_exists("%s/%s.job" % [JOBS_DIR, job_id]) \
		or FileAccess.file_exists("%s/%s.json" % [JOBS_DIR, job_id])


## {points, extruding, bounds_min, bounds_max, kind} for a v1 job; a v2 job
## carries moves (PrintMoves; `PrintJob.moves_to_points` for the old form), limits, line_width_mm, layer_height_mm, filament_mm,
## extrusion_mm, volume_mm3, additive, total_s, layers, layer_starts, layer_z.
static func load(job_id: String) -> Dictionary:
	if job_id.is_empty():
		return {}
	var p2 := "%s/%s.job" % [JOBS_DIR, job_id]
	if FileAccess.file_exists(p2):
		return _load_v2(p2)
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


static func _load_v2(path: String) -> Dictionary:
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return {}
	var v: Variant = fh.get_var(false)
	fh.close()
	if not (v is Dictionary):
		return {}
	var d := v as Dictionary
	var n := int(d.get("n", 0))
	var a: PackedVector3Array = d.get("a", PackedVector3Array())
	var b: PackedVector3Array = d.get("b", PackedVector3Array())
	var f: PackedFloat32Array = d.get("f", PackedFloat32Array())
	var e: PackedFloat32Array = d.get("e", PackedFloat32Array())
	var r: PackedByteArray = d.get("r", PackedByteArray())
	if a.size() < n or b.size() < n:
		return {}
	var moves := PrintMoves.new()
	moves.p0 = a.slice(0, n)
	moves.p1 = b.slice(0, n)
	moves.feed = f.slice(0, n)
	moves.e = e.slice(0, n)
	moves.rapid = r.slice(0, n)
	moves.feed.resize(n)
	moves.e.resize(n)
	moves.rapid.resize(n)
	for i in range(f.size(), n):
		moves.feed[i] = 30.0
	moves.line.resize(n)
	for i in n:
		moves.line[i] = i + 1
	var plan: Dictionary = {}
	var pd: Variant = d.get("plan", {})
	if pd is Dictionary and int((pd as Dictionary).get("n", 0)) == n:
		plan = (pd as Dictionary).duplicate()
		plan["moves"] = moves
		plan["pm"] = moves
	return {
		"ok": true,
		"plan": plan,
		"moves": moves,
		"bounds_min": d.get("bmin", Vector3.ZERO), "bounds_max": d.get("bmax", Vector3.ZERO),
		"kind": str(d.get("kind", "")), "name": str(d.get("name", "")),
		"limits": d.get("limits", {}),
		"line_width_mm": float(d.get("line_width_mm", 0.4)),
		"layer_height_mm": float(d.get("layer_height_mm", 0.2)),
		"filament_mm": float(d.get("filament_mm", 1.75)),
		"extrusion_mm": float(d.get("extrusion_mm", 0.0)),
		"volume_mm3": float(d.get("volume_mm3", 0.0)),
		"additive": bool(d.get("additive", true)),
		"total_s": float(d.get("total_s", 0.0)),
		"layers": int(d.get("layers", 0)),
		"layer_starts": d.get("layer_starts", PackedInt32Array()),
		"layer_z": d.get("layer_z", PackedFloat32Array()),
		"mode": str(d.get("mode", "")),
	}

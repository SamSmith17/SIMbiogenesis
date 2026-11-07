class_name TcExport
extends RefCounted

## Files from a TC design: a GLB of the whole assembly (metres, one mesh,
## for any 3D program or a game), a binary STL (millimetres, for CAD / a
## printer), the bill of materials as CSV and the design as JSON. Written to
## `user://tclab_designs/<name>/` unless a folder is given.

const ROOT := "user://tclab_designs"


static func folder_for(name: String) -> String:
	var safe := name.strip_edges().to_lower().replace(" ", "_")
	var clean := ""
	for ch in safe:
		if ch.is_valid_identifier() or ch in "0123456789-_":
			clean += ch
	if clean.is_empty():
		clean = "assembly"
	return "%s/%s" % [ROOT, clean]


## Write every file. Returns {ok, dir, files: [paths], error}.
static func write_all(d: Dictionary, dir: String = "") -> Dictionary:
	var spec: Dictionary = d["spec"]
	var base := dir if not dir.is_empty() else folder_for(str(spec.get("name", "assembly")))
	DirAccess.make_dir_recursive_absolute(base)
	var stem := base.get_file()
	var files: Array = []
	var glb := "%s/%s.glb" % [base, stem]
	var err := write_glb(d, glb)
	if err == OK:
		files.append(glb)
	var stl := "%s/%s.stl" % [base, stem]
	if write_stl(d, stl):
		files.append(stl)
	var csv := "%s/%s_bom.csv" % [base, stem]
	if _write_text(csv, TcBom.to_csv(d["bom"])):
		files.append(csv)
	var js := "%s/%s.json" % [base, stem]
	if _write_text(js, JSON.stringify(spec, "  ")):
		files.append(js)
	return {"ok": files.size() == 4, "dir": base, "files": files,
		"error": "" if err == OK else "GLB export failed (%d)" % err}


static func write_glb(d: Dictionary, path: String) -> int:
	var node := TcBuilder.new()
	node.name = str((d["spec"] as Dictionary).get("name", "Assembly"))
	node.build(d, {"flat": true})
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(node, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	node.free()
	return err


## Binary STL, millimetres.
static func write_stl(d: Dictionary, path: String) -> bool:
	var tris := TcBuilder.triangles_mm(d)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var header := PackedByteArray()
	header.resize(80)
	var title := ("SIMbiogenesis TC assembly (mm)").to_utf8_buffer()
	for i in mini(title.size(), 80):
		header[i] = title[i]
	f.store_buffer(header)
	var n := int(tris.size() / 3.0)
	f.store_32(n)
	var i := 0
	while i + 2 < tris.size():
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		# Our triangles are clockwise from outside; STL wants counter-
		# clockwise, so write them reversed with the outward normal.
		var nrm := (c - a).cross(b - a).normalized()
		for v in [nrm, a, c, b]:
			f.store_float((v as Vector3).x)
			f.store_float((v as Vector3).y)
			f.store_float((v as Vector3).z)
		f.store_16(0)
		i += 3
	f.close()
	return true


static func _write_text(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

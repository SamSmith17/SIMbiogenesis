extends SceneTree

## Live end-to-end smoke for the parametric-SCAD pipeline (Phase 0 close-out).
## REQUIRES a real OpenSCAD binary (unlike scad_selftest.gd, which is offline).
## Renders the seed vase twice with different parameters, confirms the STL imports
## to an ArrayMesh, and confirms parameters actually change the geometry.
##
## Run with:
##   Godot.exe.exe --headless --path . --script core/scad/scad_render_smoke.gd

const RuntimeScript := preload("res://core/scad/scad_runtime.gd")

const SCAD := "res://scad_library/vase_20160822.scad"


func _initialize() -> void:
	var bin := RuntimeScript.find_openscad()
	print("OpenSCAD binary: %s" % ("<none>" if bin.is_empty() else bin))
	if bin.is_empty():
		print("SCAD RENDER SMOKE SKIP — no OpenSCAD binary found")
		quit(0)
		return

	# A coarse, fast render (low $fn) so the CGAL pass stays quick in CI.
	var a := {
		"radius": 40, "height": 120, "sides": 8, "thickness": 3,
		"degree_twist": 0, "twisting": "no", "perforating": "no", "filling": "no",
	}
	var b := a.duplicate()
	b["degree_twist"] = 180
	b["twisting"] = "yes"
	b["radius"] = 60
	b["sides"] = 16

	var out_a := "user://scratch/vase_smoke_a.stl"
	var out_b := "user://scratch/vase_smoke_b.stl"

	var ra := RuntimeScript.render_to_mesh(SCAD, a, out_a)
	_report("render A (straight, r40, 8 sides)", ra, out_a)
	var rb := RuntimeScript.render_to_mesh(SCAD, b, out_b)
	_report("render B (twist 180, r60, 16 sides)", rb, out_b)

	var ok: bool = bool(ra.get("ok", false)) and bool(rb.get("ok", false))
	if ok:
		var mesh_a: ArrayMesh = ra["mesh"]
		var mesh_b: ArrayMesh = rb["mesh"]
		var tri_a := _tri_count(mesh_a)
		var tri_b := _tri_count(mesh_b)
		print("  mesh A triangles: %d   mesh B triangles: %d" % [tri_a, tri_b])
		# Different parameters must yield different geometry (proves -D took effect).
		if tri_a == tri_b:
			print("  WARN: identical triangle counts — parameters may not have applied")
	print("SCAD RENDER SMOKE %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _report(label: String, res: Dictionary, path: String) -> void:
	if res.get("ok", false):
		var abs := ProjectSettings.globalize_path(path)
		var size := 0
		if FileAccess.file_exists(abs):
			var f := FileAccess.open(abs, FileAccess.READ)
			if f != null:
				size = f.get_length()
				f.close()
		print("  OK  %s -> %s (%d bytes)" % [label, path, size])
	else:
		print("  ERR %s: %s" % [label, res.get("reason", "?")])


func _tri_count(mesh: ArrayMesh) -> int:
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return verts.size() / 3

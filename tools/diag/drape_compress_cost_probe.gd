extends RefCounted

## Sandbox, read-only: how long ImageryService builds each drape texture on
## the main thread (mipmaps + DXT1, _make_drape_texture) for this world's
## cached imagery layers, and the BC7 path for comparison. Copies of the
## images are used; nothing is written.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/drape_compress_cost_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 120:
		await tree.process_frame
	var lat := float(main.get("latitude"))
	var tok := "%.4f_" % lat
	var dir := "user://terrain_cache/imagery"
	var d := DirAccess.open(dir)
	if d == null:
		return {"ok": false, "why": "no imagery cache"}
	var files: Array = []
	for f in d.get_files():
		if f.ends_with(".png") and f.contains(tok):
			files.append(f)
	files.sort()
	var total := 0.0
	for f in files:
		var img := Image.new()
		if img.load("%s/%s" % [dir, f]) != OK:
			continue
		var t0 := Time.get_ticks_usec()
		var tex := ImageryService._make_drape_texture(img.duplicate() as Image)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		total += ms
		print("drapecost: %-70s %5d x %5d  main-thread build %8.1f ms  (%s)" % [f, img.get_width(), img.get_height(), ms, str(tex.get_image().get_format()) if tex != null else "-"])
	print("drapecost: %d layers, %.1f ms in all" % [files.size(), total])
	return {"ok": true}

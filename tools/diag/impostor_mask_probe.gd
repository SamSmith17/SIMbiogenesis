extends RefCounted

## Sandbox, read-only on disk: the impostor sets this world has loaded, their
## mask textures' format and size, and what an R8 mask (the shader reads
## only .r, no mipmaps) would save. Converts every loaded mask in memory,
## checks every pixel's red byte is unchanged, and reports the texture memory
## before and after. Nothing is saved.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/impostor_mask_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var sets: Dictionary = {}
	for _w in 40:
		for _i in 30:
			await tree.process_frame
		sets = VegImpostorBaker._sets
		if not sets.is_empty():
			break
	for _i in 120:
		await tree.process_frame
	sets = VegImpostorBaker._sets
	var n := 0
	var bytes := 0
	var fmt := {}
	for k in sets:
		var iset: VegImpostorSet = sets[k]
		if iset == null or iset.mask == null:
			continue
		var im := iset.mask.get_image()
		n += 1
		bytes += im.get_data().size()
		fmt[im.get_format()] = int(fmt.get(im.get_format(), 0)) + 1
	var mem0 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	print("impmask: %d impostor sets loaded, masks %.1f MB in all, formats %s; texture memory %.1f MB" % [
		n, float(bytes) / 1048576.0, str(fmt), mem0 / 1048576.0])
	var same := true
	var after_bytes := 0
	for k in sets:
		var iset: VegImpostorSet = sets[k]
		if iset == null or iset.mask == null:
			continue
		var a := iset.mask.get_image()
		if a.get_format() != Image.FORMAT_RGBA8:
			continue
		var b := a.duplicate() as Image
		b.convert(Image.FORMAT_R8)
		var da := a.get_data()
		var db := b.get_data()
		for i in db.size():
			if db[i] != da[i * 4]:
				same = false
				break
		iset.mask.set_image(b)
		after_bytes += db.size()
	for _i in 30:
		await tree.process_frame
	var mem1 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	print("impmask: as R8 the masks are %.1f MB; every red byte unchanged %s; texture memory %.1f -> %.1f MB" % [
		float(after_bytes) / 1048576.0, "PASS" if same else "FAIL", mem0 / 1048576.0, mem1 / 1048576.0])
	return {"ok": same}

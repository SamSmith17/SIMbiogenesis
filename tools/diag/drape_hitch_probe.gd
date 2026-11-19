extends RefCounted

## Sandbox, read-only: the main-thread hitch of a drape arriving. Re-requests
## this world's detail layer from the cache through ImageryService's public
## call (tag "drape_probe", so the loader ignores it) three times, and times
## the call itself, the worst frame until imagery_ready arrives, and the
## wait. Prints the texture's size and format so both code paths can be
## compared.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/drape_hitch_probe.gd

func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var svc: Node = main.get_node_or_null("/root/ImageryService")
	if loader == null or svc == null:
		return {"ok": false, "why": "no loader or imagery service"}
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var half := float(loader.get("_detail_half_extent"))
	var tier := int(loader.call("_tier_for_tag", "detail"))
	var tpx := int(loader.call("_detail_target_px", tier))
	var mz := 19  # TerrainLoader.DETAIL_MAX_ZOOM
	var got := [null]
	var on_ready := func(_k: String, tex: ImageTexture, t: String) -> void:
		if t == "drape_probe":
			got[0] = tex
	svc.connect("imagery_ready", on_ready)
	var ok := true
	for rep in 3:
		got[0] = null
		await tree.process_frame
		await tree.process_frame
		var t0 := Time.get_ticks_usec()
		svc.call("request_imagery", lat, lon, half, tpx, "drape_probe", mz)
		var call_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var worst := call_ms
		var tf := Time.get_ticks_usec()
		var waited := 0
		while got[0] == null and waited < 600:
			await tree.process_frame
			var now := Time.get_ticks_usec()
			worst = maxf(worst, float(now - tf) / 1000.0)
			tf = now
			waited += 1
		var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var tex: ImageTexture = got[0]
		if tex == null:
			ok = false
			print("drapehitch: no texture after %d frames" % waited)
			continue
		var im := tex.get_image()
		print("drapehitch: run %d: call %.1f ms, worst frame %.1f ms, texture after %.1f ms (%d frames): %d x %d, format %d, mipmaps %s, bytes hash %d" % [
			rep, call_ms, worst, total_ms, waited, tex.get_width(), tex.get_height(), im.get_format(), str(im.has_mipmaps()),
			hash(im.get_data())])
	svc.disconnect("imagery_ready", on_ready)
	return {"ok": ok}

extends RefCounted
## Per-world terrain imagery, end to end, on a world that arrived in a pack
## (its record says {"saved_tier": S, "mode": "saved"}) on a computer set to
## another quality tier L. Run it on the friend's side: install a pack into an
## empty sandbox (tools\harness.ps1 -EmptyUser -Capture assetpack-import …),
## then with APPDATA at that sandbox:
##   Godot --path . -- --world=<id> --run-script=res://tools/checks/terrain_imagery_check.gd
## 1. SAVED: every layer the saved tier has on disk is shown at S, nothing
##    downloaded for it; the record still says saved.
## 2. MY QUALITY, OFFLINE (ImageryService.offline_for_test): layers of L that
##    are cached load at L; the ones that would have to be downloaded fail and
##    fall back to S's copy — the terrain never loses a layer it had.
## 3. MY QUALITY, ONLINE (only when the machine has internet): the missing L
##    layers download and are shown at L, no fallback.
## 4. Back to SAVED: S again, instantly; the record follows every switch.
## Prints the GPU cost of both. Changes only the sandbox.

const _ImgSvc := preload("res://core/terrain/imagery_service.gd")
## A real 8192 px download can take minutes; offline steps settle in seconds.
const WAIT_S := 600.0


func run(main: Node, harness: Node) -> Dictionary:
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null or not loader.has_method("get_world_imagery"):
		return {"ok": false, "why": "no TerrainLoader with per-world imagery"}
	var fails: Array[String] = []
	var st: Dictionary = loader.call("get_world_imagery")
	var saved := int(st["saved_tier"])
	var local := int(st["local_tier"])
	print("imagery-check: saved %s (%s GPU), this computer %s (%s GPU), mode %s" % [
		TerrainImageryPlan.tier_name(saved), TerrainImageryPlan.format_bytes(int(st.get("vram_saved", 0))),
		TerrainImageryPlan.tier_name(local), TerrainImageryPlan.format_bytes(int(st["vram_local"])), st["mode"]])
	if saved < 0 or saved == local:
		return {"ok": false, "why": "this world has no saved imagery at another tier (saved %d, local %d)" % [saved, local]}
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var dh := float(loader.call("get_terrain_extents")["detail_half_extent_m"])
	var ov := TerrainImageryPlan.config_overrides()

	# 1. Saved.
	await _settle(main, loader)
	st = loader.call("get_world_imagery")
	_expect(fails, str(st["mode"]) == "saved", "1 the imported world opens with its saved imagery")
	for tag in TerrainImageryPlan.TAGS:
		var l := TerrainImageryPlan.layer(tag, saved, lat, lon, dh, ov)
		if l.is_empty() or not TerrainImageryPlan.is_cached(l):
			continue
		_expect(fails, int((st["shown"] as Dictionary).get(tag, -1)) == saved,
			"1 %s shown at the saved tier (%s)" % [tag, str((st["shown"] as Dictionary).get(tag))])
	_expect_halves(fails, loader, "1")
	_expect(fails, _record_mode() == "saved", "1 world.json says saved")

	# 2. My quality, offline.
	_ImgSvc.offline_for_test = true
	await _switch(main, loader, harness, "local")
	st = loader.call("get_world_imagery")
	var fell: Array = st["fell_back"]
	for tag in TerrainImageryPlan.TAGS:
		var ll := TerrainImageryPlan.layer(tag, local, lat, lon, dh, ov)
		var sl := TerrainImageryPlan.layer(tag, saved, lat, lon, dh, ov)
		var shown := int((st["shown"] as Dictionary).get(tag, -1))
		if ll.is_empty():
			continue
		if TerrainImageryPlan.is_cached(ll):
			_expect(fails, shown == local and not fell.has(tag), "2 %s cached at my quality: shown at it" % tag)
		elif TerrainImageryPlan.is_cached(sl):
			_expect(fails, shown == saved and fell.has(tag), "2 %s not downloadable: fell back to the saved copy (shown %d)" % [tag, shown])
	print("imagery-check: offline, fell back for %s" % str(fell))
	_expect_halves(fails, loader, "2")
	_expect(fails, _record_mode() == "local", "2 world.json says local")

	# 3. My quality, online.
	_ImgSvc.offline_for_test = false
	if _online():
		loader.call("set_world_imagery_mode", "saved")
		await _settle(main, loader)
		await _switch(main, loader, harness, "local")
		st = loader.call("get_world_imagery")
		_expect(fails, (st["fell_back"] as Array).is_empty(), "3 online: nothing fell back (%s)" % str(st["fell_back"]))
		for tag in st["shown"]:
			_expect(fails, int(st["shown"][tag]) == local, "3 online: %s shown at my quality" % tag)
		_expect_halves(fails, loader, "3")
	else:
		print("imagery-check: SKIP step 3 — no internet here")

	# 4. Back to saved.
	await _switch(main, loader, harness, "saved")
	st = loader.call("get_world_imagery")
	_expect(fails, (st["shown"] as Dictionary).get("detail", -1) == saved, "4 back to the saved detail drape")
	_expect_halves(fails, loader, "4")
	_expect(fails, _record_mode() == "saved", "4 world.json says saved again")

	# 5. A switch abandoned mid-flight: my quality, then straight back to saved
	#    before anything lands. Late results of the abandoned request (a BC7
	#    site patch still compressing) must not reach the screen.
	loader.call("set_world_imagery_mode", "local")
	for _i in 3:
		await main.get_tree().process_frame
	loader.call("set_world_imagery_mode", "saved")
	await _settle(main, loader)
	st = loader.call("get_world_imagery")
	for tag in TerrainImageryPlan.TAGS:
		var sl := TerrainImageryPlan.layer(tag, saved, lat, lon, dh, ov)
		var shown := int((st["shown"] as Dictionary).get(tag, -1))
		if sl.is_empty():
			_expect(fails, shown == -1, "5 %s: the saved tier has none, none on screen (shown %d)" % [tag, shown])
		elif TerrainImageryPlan.is_cached(sl):
			_expect(fails, shown == saved, "5 %s back at the saved tier (shown %d)" % [tag, shown])
	if TerrainImageryPlan.layer("site", saved, lat, lon, dh, ov).is_empty():
		_expect(fails, loader.get("_site_drape") == null, "5 no site patch drape left over")
	_expect_halves(fails, loader, "5")
	for f in fails:
		print("imagery-check: FAIL — %s" % f)
	print("imagery-check: %s (%d failure(s))" % ["PASS" if fails.is_empty() else "FAIL", fails.size()])
	return {"ok": fails.is_empty(), "fails": fails}



func _expect(fails: Array[String], ok: bool, what: String) -> void:
	print("imagery-check: %s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails.append(what)


## The hyper / site drapes on screen carry the size they were fetched at.
func _expect_halves(fails: Array[String], loader: Node, step: String) -> void:
	if loader.get("_hyper_drape") != null:
		_expect(fails, absf(float(loader.get("_hyper_half_m")) - float(loader.get("_hyper_drape_half"))) < 0.5,
			"%s hyper drape and its size agree (%.0f m)" % [step, float(loader.get("_hyper_drape_half"))])
	if loader.get("_site_drape") != null:
		_expect(fails, absf(float(loader.get("_site_half_m")) - float(loader.get("_site_drape_half"))) < 0.5,
			"%s site drape and its size agree (%.0f m)" % [step, float(loader.get("_site_drape_half"))])


func _switch(main: Node, loader: Node, _harness: Node, mode: String) -> void:
	loader.call("set_world_imagery_mode", mode)
	WorldSession.save_now(main, false, false)
	await _settle(main, loader)


## Wait until no imagery request is in flight (or WAIT_S).
func _settle(main: Node, _loader: Node) -> void:
	var tree := main.get_tree()
	var svc := tree.root.get_node_or_null("ImageryService")
	var t0 := Time.get_ticks_msec()
	var idle_frames := 0
	while Time.get_ticks_msec() - t0 < int(WAIT_S * 1000.0):
		await tree.process_frame
		var busy := svc != null and (bool(svc.get("_busy")) or not (svc.get("_pending") as Array).is_empty()
			or not (svc.get("_hq_tasks") as Dictionary).is_empty())
		idle_frames = 0 if busy else idle_frames + 1
		if idle_frames > 90:
			return


func _record_mode() -> String:
	var rec := WorldSession.active_record()
	var ti: Dictionary = rec.get("terrain_imagery", {}) if rec.get("terrain_imagery", {}) is Dictionary else {}
	return str(ti.get("mode", ""))


func _online() -> bool:
	return IP.resolve_hostname("server.arcgisonline.com", IP.TYPE_IPV4) != ""

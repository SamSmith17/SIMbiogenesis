extends RefCounted
## Every kind of structure put up and taken down by the crew, piece by piece
## (sandbox, Walton):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/structure_build_check.gd -Label structure_build -Timeout 3000
## Packed kits of a geodesic dome, a toroid, a Linkage Lab frame, a gantry, a
## flat-pack daybed and a shiftpod (a GLB) on open ground by the festival
## field, each handed to the nearest crew (queue_item). For every one, while
## the crew builds: the shared build site draws it (PalletRackBuildSite over
## StructureUnits), the model — the ghost — never shows, it starts with
## nothing up, goes up piece by piece and never loses a piece, and stands for
## real at the end. Then each is packed up the same way backwards: nothing
## comes off at the start, pieces only come off, it ends as its crate. A shot
## of each half built and half struck. Env SB_ONLY=dome,linkage limits the set.

var _fails: Array = []
const SHOT_DIR := "user://screenshots/structure_build"


func _ok(cond: bool, what: String) -> void:
	print("structure-build %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	img.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("structure-build shot: %s" % name)


func _aim(main: Node, at: Vector2, h: float) -> void:
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.get("_cam") if view != null else null
	if cam == null:
		return
	cam.set("_h_target", h)
	cam.set("_h", h)
	cam.set("focus", at)
	cam.set("_focus_target", at)


## A shot camera of the check's own, 10 m off a structure at 6 m, looking at
## it (a camera claim over the settlement view).
var _cam: Camera3D = null


func _look_at_site(main: Node, at: Vector2, r: float = 9.0) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "StructureBuildCheckCam"
		_cam.fov = 55.0
		main.add_child(_cam)
		main.call("push_camera_claim", "structure_build_check", {"camera_id": _cam.get_instance_id()})
	var gy := TerrainSurfaceQuery.ground_height_at(main, at.x, at.y)
	var target := Vector3(at.x, gy + 1.8, at.y)
	var eye := target + Vector3(r * 0.8, r * 0.55, r * 0.9)
	_cam.global_transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)


func _free_spot(loader: Node, centre: Vector2, half: float, avoid: Array) -> Vector2:
	for r in [0.0, 30.0, 45.0, 60.0, 80.0, 100.0, 130.0, 160.0, 200.0, 250.0]:
		for k in 16:
			var a := float(k) * TAU / 16.0
			var c: Vector2 = centre + Vector2(cos(a), sin(a)) * float(r)
			var ok := true
			for q in avoid:
				if c.distance_to(q) < half * 2.6:
					ok = false
			for dx in [-half, 0.0, half]:
				for dz in [-half, 0.0, half]:
					if ok and not str(loader.call("camp_area_at", c + Vector2(float(dx), float(dz)))).is_empty():
						ok = false
			if ok and loader.has_method("festival_ground_free") and not bool(loader.call("festival_ground_free", c, half)):
				ok = false
			if ok:
				return c
	return Vector2.INF


## The kits: label -> {model_id, extra}.
func _kits() -> Dictionary:
	var out := {}
	var dome: Dictionary = DomeLabPresets.builtins()[0]
	out["dome"] = {"model_id": DomeLabBuilder.MODEL_ID, "extra": {"domelab_spec": dome.get("spec", dome)}}
	var tor: Dictionary = ToroidLabPresets.builtins()[0]
	out["toroid"] = {"model_id": ToroidLabBuilder.MODEL_ID, "extra": {"toroid_spec": tor.get("spec", tor)}}
	var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/linkage/presets/starshade_default.json"))
	out["linkage"] = {"model_id": LinkageStructureBuilder.MODEL_ID, "extra": {"linkage_spec": cfg}}
	var gan: Dictionary = GantryLabPresets.builtins()[0]
	out["gantry"] = {"model_id": GantryLabBuilder.MODEL_ID, "extra": {"gantry_spec": gan.get("spec", gan)}}
	var fp: Dictionary = FlatpackPresets.builtin("daybed")
	out["daybed"] = {"model_id": FlatpackBuilder.MODEL_ID, "extra": {"flatpack_spec": fp.get("spec", fp)}}
	out["shiftpod"] = {"model_id": "shiftpod", "extra": {}}
	return out


func _site(main: Node, pid: String) -> PalletRackBuildSite:
	return PalletRackBuildSite.site_for(main, pid)


## {installed, total, model (ghost showing), unplanned}
func _census(main: Node, pid: String) -> Dictionary:
	var out := {"installed": 0, "total": 0, "model": false, "unplanned": 0, "site": false}
	var prop := PlacedPropService._find_prop_node(main, pid)
	if prop == null:
		return out
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	out["model"] = model != null and model.is_visible_in_tree() and bool(prop.get_meta("under_construction", false))
	var site := prop.get_node_or_null(PalletRackBuildSite.NODE_NAME) as PalletRackBuildSite
	if site == null or not site.is_running():
		return out
	out["site"] = true
	var st := site.last_state()
	var units: Dictionary = st.get("units", {})
	for id in units:
		var s: Dictionary = units[id]
		out["total"] = int(out["total"]) + 1
		if float(s["g"]) <= 0.001 and (s["xf"] as Transform3D).is_equal_approx(Transform3D()):
			out["installed"] = int(out["installed"]) + 1
	var root := site.get_node_or_null("RackUnits")
	if root != null:
		for c in root.get_children():
			if not units.has(str(c.get_meta("unit_id", ""))) and (c as Node3D).visible:
				out["unplanned"] = int(out["unplanned"]) + 1
	return out


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await _settle(tree, 20)
	var sgv := ServiceLocator.graph()
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	_ok(sgv != null and loader != null, "graph view + terrain loader are up")
	if sgv == null or loader == null:
		return {"ok": false}
	var sd: SiteDeployDirector = sgv.call("site_deploy")
	sd.clear()
	main.set("time_scale", 0.001)
	var day0: float = floor(float(main.call("get_absolute_hours")) / 24.0) * 24.0
	main.call("set_absolute_hours", day0 + 11.0)
	PopTestPrefs.set_festival_target_people(0)
	main.call("open_festival_mode")
	for _i in 900:
		await tree.process_frame
		if bool(main.call("festival_mode_active")):
			break
	await _settle(tree, 30)
	if loader.has_method("apply_festival_population_target"):
		loader.call("apply_festival_population_target")
	main.set("time_scale", 0.02)
	await tree.create_timer(4.0).timeout
	main.set("time_scale", 0.001)
	var only := OS.get_environment("SB_ONLY").split(",", false)
	var kits := _kits()
	var placed := {}    # label -> {pid, at}
	var avoid: Array = []
	var centre := SiteCentre.xz(main)
	for label in kits:
		if not only.is_empty() and not only.has(label):
			continue
		var at := _free_spot(loader, centre, 9.0, avoid)
		if at == Vector2.INF:
			_ok(false, "open ground for the %s" % label)
			continue
		avoid.append(at)
		var extra: Dictionary = (kits[label]["extra"] as Dictionary).duplicate(true)
		extra["packed"] = true
		var r: Dictionary = PlacedPropService.place_model_at_xz(main, str(kits[label]["model_id"]), at.x, at.y, extra)
		_ok(bool(r.get("ok", false)), "packed %s placed at (%.0f, %.0f)" % [label, at.x, at.y])
		if bool(r.get("ok", false)):
			placed[label] = {"pid": str(r["prop_id"]), "at": at}
	await _settle(tree, 10)
	await _phase(main, tree, sd, placed, SiteDeploySchedule.ACTION_DEPLOY)
	await _phase(main, tree, sd, placed, SiteDeploySchedule.ACTION_PACKUP)
	main.call("pop_camera_claim", "structure_build_check")
	if _cam != null:
		_cam.queue_free()
	return {"ok": _fails.is_empty(), "failures": _fails}


func _phase(main: Node, tree: SceneTree, sd: SiteDeployDirector, placed: Dictionary, action: String) -> void:
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	var word := "build" if deploy else "pack-up"
	for label in placed:
		var q: Dictionary = sd.queue_item("prop", str(placed[label]["pid"]), action)
		_ok(bool(q.get("ok", false)), "%s %s handed to a crew %s" % [label, word, str(q.get("error", ""))])
	# Wait for every site to come up (a linkage pack-up folds first).
	var t := 0.0
	main.set("time_scale", 0.004)
	while t < 40.0:
		var all_up := true
		for label in placed:
			if not bool(_census(main, str(placed[label]["pid"]))["site"]):
				all_up = false
		if all_up:
			break
		await tree.create_timer(0.5).timeout
		t += 0.5
	var stats := {}
	for label in placed:
		var pid := str(placed[label]["pid"])
		var c := _census(main, pid)
		print("structure-build %s %s start: %s" % [label, word, str(c)])
		_ok(bool(c["site"]), "%s: the crew's build site draws the %s" % [label, word])
		_ok(int(c["unplanned"]) == 0, "%s: every piece is in the plan (%d drawn as they stand)" % [label, int(c["unplanned"])])
		if deploy:
			_ok(int(c["installed"]) <= 1, "%s: nothing stands at the start (%d of %d up)" % [label, int(c["installed"]), int(c["total"])])
		else:
			_ok(int(c["installed"]) >= int(c["total"]) - 1 and int(c["total"]) > 0,
				"%s: it all stands when the pack-up starts (%d of %d)" % [label, int(c["installed"]), int(c["total"])])
		stats[label] = {"ghost": 0, "back": 0, "last": int(c["installed"]), "total": int(c["total"]),
			"shot": false, "done": false, "max": int(c["installed"]), "min": int(c["installed"])}
	main.set("time_scale", 0.1)
	t = 0.0
	while t < 1500.0:
		await tree.create_timer(0.1).timeout
		t += 0.1
		var all_done := true
		for label in placed:
			var pid := str(placed[label]["pid"])
			var s: Dictionary = stats[label]
			if bool(s["done"]):
				continue
			var rec := PlacedPropService.get_prop_record(main, pid)
			var finished := (not bool(rec.get("packed", false))) if deploy else bool(rec.get("packed", false))
			var c := _census(main, pid)
			# Done once the record flipped AND the drawn build has caught up
			# (the finished prop's site carries the last pieces on).
			if finished and deploy and OS.get_environment("SB_TRACE") == "1":
				var s1 := _site(main, pid)
				print("structure-build trace %s: %s %s" % [label, str(c), s1.progress_line() if s1 != null else "no site"])
			if finished and (not bool(c["site"]) or not deploy or int(c["installed"]) >= int(c["total"])):
				if deploy and bool(c["site"]):
					s["max"] = maxi(int(s["max"]), int(c["installed"]))
				s["done"] = true
				continue
			all_done = false
			if bool(c["model"]):
				s["ghost"] = int(s["ghost"]) + 1
			if not bool(c["site"]):
				continue
			var n := int(c["installed"])
			# Pieces only go on (a build) / only come off (a pack-up).
			if (deploy and n < int(s["last"]) - 1) or (not deploy and n > int(s["last"]) + 1):
				s["back"] = int(s["back"]) + 1
				var site0 := _site(main, pid)
				print("structure-build %s %s went back %d -> %d: %s" % [label, word, int(s["last"]), n,
					site0.progress_line() if site0 != null else "no site"])
			s["last"] = n
			s["max"] = maxi(int(s["max"]), n)
			s["min"] = mini(int(s["min"]), n)
			var tot := maxi(int(c["total"]), 1)
			if not bool(s["shot"]) and float(n) / float(tot) > 0.35 and float(n) / float(tot) < 0.75:
				s["shot"] = true
				var keep_ts := float(main.get("time_scale"))
				main.set("time_scale", 0.001)
				_look_at_site(main, placed[label]["at"], 11.0 if label in ["toroid", "dome", "linkage"] else 6.0)
				await tree.create_timer(1.2).timeout
				await _shot(main, "%s_%s_half" % [label, word])
				main.set("time_scale", keep_ts)
		if all_done:
			break
	for label in placed:
		var s: Dictionary = stats[label]
		var pid := str(placed[label]["pid"])
		_ok(int(s["ghost"]) == 0, "%s: the ghost never showed during the %s (%d samples)" % [label, word, int(s["ghost"])])
		_ok(int(s["back"]) == 0, "%s: pieces only %s" % [label, "went on" if deploy else "came off"])
		if deploy:
			_ok(int(s["max"]) >= int(s["total"]) - 1, "%s: every piece went up (%d of %d)" % [label, int(s["max"]), int(s["total"])])
		else:
			_ok(int(s["min"]) <= 1, "%s: every piece came down (%d left)" % [label, int(s["min"])])
		_ok(bool(s["done"]), "%s: the %s finished (%.0f s real)" % [label, word, t])
		_ok(bool(s["shot"]), "%s: caught half way" % label)
	await _settle(tree, 30)
	for label in placed:
		var pid := str(placed[label]["pid"])
		var prop := PlacedPropService._find_prop_node(main, pid)
		var rec := PlacedPropService.get_prop_record(main, pid)
		if deploy:
			var model := prop.get_node_or_null("ModelRoot") as Node3D if prop != null else null
			_ok(model != null and model.is_visible_in_tree() and not bool(prop.get_meta("under_construction", false)),
				"%s: the real structure stands at the end" % label)
		else:
			_ok(bool(rec.get("packed", false)) and prop != null and not bool(prop.get_meta("under_construction", false)),
				"%s: packed back into its crate" % label)
	for label in placed:
		_look_at_site(main, placed[label]["at"], 11.0 if label in ["toroid", "dome", "linkage"] else 6.0)
		await tree.create_timer(0.8).timeout
		await _shot(main, "%s_after_%s" % [label, word])

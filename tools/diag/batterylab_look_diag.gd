extends SceneTree

## WINDOWED look check (not a selftest — it needs a GPU): every built-in
## battery pack (BattPresets) as the builder draws it, ASSEMBLED, EXPLODED and
## in CUTAWAY, one row per pack, in an empty studio. What only a picture
## settles: cells standing in their case, busbars on the terminals they
## join, the balance harness reaching the BMS, the leads to the front
## terminals, lead-acid plates inside their block.
##   godot --path . --windowed --resolution 1280x720 --script tools/diag/batterylab_look_diag.gd
##     [-- --out=<png>] [-- --only=rack_48v_105,diy_16s_280] [-- --cell=480x320]
##     [-- --views=assembled,exploded,cutaway,top]
## Writes user://batterylab_look.png (run with APPDATA at a scratch folder,
## or the PNG lands in the player's user data).

var CW := 400
var CH := 280
const VIEWS := ["assembled", "exploded", "cutaway"]


func _initialize() -> void:
	_run()


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--%s=" % name):
			return str(a).substr(name.length() + 3)
	return def


func _studio() -> Node3D:
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	root3d.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, -140.0, 0.0)
	fill.light_energy = 0.4
	root3d.add_child(fill)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.35, 0.36, 0.38)
	ground.material_override = gm
	root3d.add_child(ground)
	return root3d


func _run() -> void:
	await process_frame
	var root3d := _studio()
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.fov = 35.0
	cam.make_current()
	var only := _arg("only", "")
	var cell := _arg("cell", "")
	if cell.contains("x"):
		CW = int(cell.get_slice("x", 0))
		CH = int(cell.get_slice("x", 1))
	if _arg("banks", "") != "":
		await _run_banks(root3d, cam)
		return
	var views: Array = Array(_arg("views", ",".join(PackedStringArray(VIEWS))).split(","))
	var ids: Array = []
	for b in BattPresets.builtins():
		var id := str((b as Dictionary)["id"])
		if only.is_empty() or only.split(",").has(id):
			ids.append(id)
	var grid := Image.create(CW * views.size(), CH * maxi(ids.size(), 1), false, Image.FORMAT_RGBA8)
	for k in ids.size():
		var d := BattDesign.solve(BattPresets.builtin(str(ids[k])))
		var b := BattBuilder.build_from_design(d)
		root3d.add_child(b)
		var bm: AABB = b.get_meta("bounds_m")
		var sz := bm.size
		var target := bm.get_center()
		for v in views.size():
			var view := str(views[v])
			b.set_explode(0.0)
			b.set_cutaway(false)
			var reach := maxf(sz.x, maxf(sz.y, sz.z)) * 2.4 + 0.25
			var from := target + Vector3(reach * 0.62, reach * 0.55, reach * 0.75)
			match view:
				"exploded":
					b.set_explode(1.0)
					reach *= 1.6
					from = target + Vector3(reach * 0.62, reach * 0.55, reach * 0.75)
				"cutaway":
					b.set_cutaway(true)
				"top":
					b.set_cutaway(true)
					from = target + Vector3(0.001, reach * 1.1, reach * 0.15)
				"terminals", "inside", "cells":
					# Close-ups: the terminals from outside, a main lead's lug
					# and bends inside, the links on the cells.
					b.set_cutaway(view != "terminals")
					var at := _close_target(b, view)
					if at != Vector3.INF:
						target = at
						var near := 0.16 if view != "cells" else 0.22
						from = target + Vector3(near * 0.7, near * 0.75, near * 1.0)
						if view == "cells":
							# Down through the open lid: from the side the case walls are in the way.
							from = target + Vector3(near * 0.15, near * 1.5, near * 0.55)
			cam.global_position = from
			cam.look_at(target, Vector3.UP)
			target = bm.get_center()
			for i in 4:
				await process_frame
			grid.blit_rect(_grab(CW, CH), Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
		var e: Dictionary = d["electrical"]
		print("BatteryLook: %-18s %.0f x %.0f x %.0f mm  %.1f V %.0f Ah  %d cells  %s" % [ids[k],
			sz.x * 1000.0, sz.y * 1000.0, sz.z * 1000.0, float(e["v_nom"]), float(e["ah"]),
			b.cell_count(), d["arrange"]])
		b.queue_free()
		await process_frame
	var out := _arg("out", "user://batterylab_look.png")
	grid.save_png(out)
	print("BatteryLook: wrote %s  (columns: %s; rows: %s)" % [
		ProjectSettings.globalize_path(out), " / ".join(PackedStringArray(views)), ", ".join(PackedStringArray(ids))])
	quit(0)


## Banks: -- --banks=1 [--only=<case ids>]: each case whole, then close on
## its bus, a pack terminal and a fuse.
const BANK_CASES := [
	["cab_1s4p", "rack_48v_105", 1, 4, {}],
	["cab_dist", "rack_48v_105", 1, 3, {"bus": "distributor", "mount": "floor"}],
	["wall_1s2p", "wall_48v_314", 1, 2, {}],
	["agm_4s2p", "agm_12v_100", 4, 2, {"mount": "shelf"}],
	["dropin_2p", "dropin_12v_105", 1, 3, {}],
	["fla_8s1p", "fla_6v_225", 8, 1, {"fuse": "anl"}],
]


func _run_banks(root3d: Node3D, cam: Camera3D) -> void:
	var only := _arg("only", "")
	var views := ["whole", "bus", "terminal", "fuse"]
	var cases: Array = []
	for c in BANK_CASES:
		if only.is_empty() or only.split(",").has(str(c[0])):
			cases.append(c)
	var grid := Image.create(CW * views.size(), CH * maxi(cases.size(), 1), false, Image.FORMAT_RGBA8)
	for k in cases.size():
		var c: Array = cases[k]
		var pre := BattPresets.builtin(str(c[1]))
		if pre.is_empty():
			print("BatteryLook: no preset %s" % c[1])
			continue
		var bs := BankSpec.of_pack(pre, int(c[2]), int(c[3]), str(c[0]))
		for key in (c[4] as Dictionary):
			bs[key] = c[4][key]
		var d := BankDesign.solve(bs)
		var b := BankBuilder.build_from_design(d)
		root3d.add_child(b)
		var bm: AABB = b.get_meta("bounds_m")
		var tight := 0
		var worst := INF
		for cb in (d["cables"] as Array):
			if bool(cb.get("tight", false)):
				tight += 1
			worst = minf(worst, float(cb["min_r"]) / maxf(float(cb["r_bend"]), 1.0))
		for v in views.size():
			var view := str(views[v])
			var target := bm.get_center()
			var reach := maxf(bm.size.x, maxf(bm.size.y, bm.size.z)) * 1.9 + 0.3
			var from := target + Vector3(reach * 0.45, reach * 0.35, reach * 0.85)
			var id := ""
			match view:
				"bus":
					id = "bar_pos" if not b.part("bar_pos").is_empty() else "distributor"
				"terminal":
					id = "series_0_0" if not b.part("series_0_0").is_empty() else "str_pos_0"
				"fuse":
					id = "fuse_0" if not b.part("fuse_0").is_empty() else "disconnect"
			if id != "":
				var pp := b.part(id)
				if not pp.is_empty():
					var ab: AABB = pp["aabb"]
					target = ab.get_center()
					if view == "terminal":
						target = (d["packs"][0]["out_pos"] as Vector3) * 0.001
					var near := clampf(ab.size.length() * 0.9, 0.25, 0.9) if view == "bus" else 0.32
					from = target + Vector3(near * 0.55, near * 0.45, near * 1.0)
			cam.global_position = from
			cam.look_at(target, Vector3.UP)
			for i in 4:
				await process_frame
			grid.blit_rect(_grab(CW, CH), Rect2i(0, 0, CW, CH), Vector2i(v * CW, k * CH))
		print("BatteryLook: bank %-10s %d packs, %d cables, %d tight (worst %.2f of the bend radius), %s, fuse %s, bus %s" % [
			c[0], (d["packs"] as Array).size(), (d["cables"] as Array).size(), tight, worst, d["mount"],
			str((d["fuse"] as Dictionary).get("type", "none")), d["bus"]])
		b.queue_free()
		await process_frame
	var out := _arg("out", "user://batterylab_banks.png")
	grid.save_png(out)
	print("BatteryLook: wrote %s" % ProjectSettings.globalize_path(out))
	quit(0)


func _close_target(b: BattBuilder, view: String) -> Vector3:
	var ids: Array = []
	match view:
		"terminals":
			ids = ["term_pos", "post_pos"]
		"inside":
			var routes: Dictionary = b.get_meta("lead_routes", {})
			for k in ["lead_pos", "lead_breaker_term", "lead_p_neg", "lead_neg"]:
				if routes.has(k):
					var path: PackedVector3Array = routes[k]["path"]
					if not path.is_empty():
						return path[0] * 0.001
		"cells":
			ids = ["link_0", "link_1"]
	for id in ids:
		var pp := b.part(str(id))
		if not pp.is_empty():
			return (pp["aabb"] as AABB).get_center()
	return Vector3.INF


func _grab(cw: int, ch: int) -> Image:
	var img := root.get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var crop_w := mini(w, int(float(h) * float(cw) / float(ch)))
	var cell := img.get_region(Rect2i((w - crop_w) / 2, 0, crop_w, h))
	cell.resize(cw, ch)
	cell.convert(Image.FORMAT_RGBA8)
	return cell

extends RefCounted

## Solar placement check for `--run-script` (sandbox): every collector's
## placement ghost starts at its type's best orientation (SolarAim) at this
## world's latitude AND at a southern one (Main.latitude set in memory) — a
## rack faces the equator at the latitude's best tilt, a designed ground array
## the same and a designed tracker with its axis north–south, the trough on its
## east–west axis — and a placed rack keeps that facing in its record.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/solar_aim_placement_check.gd

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("solar-aim %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _wrap(a: float) -> float:
	return fposmod(a + 180.0, 360.0) - 180.0


## The compass azimuth a +Z-facing frame points to after `basis` (0 N, 180 S).
func _face_az(basis: Basis) -> float:
	var n := basis * Vector3(0.0, 0.0, 1.0)
	return fposmod(rad_to_deg(atan2(n.x, -n.z)), 360.0)


## A camera looking straight down at open, level ground near the player (the
## player's own view at Mount Vernon looks at the house), so the designed
## arrays are aimed at terrain, not a roof.
func _level_ground_camera(main: Node) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "SolarAimCheckCam"
	main.add_child(cam)
	var p := (main.get_node("Player") as Node3D).global_position
	for r in [12.0, 20.0, 30.0, 45.0]:
		for k in 8:
			var a: float = TAU * float(k) / 8.0
			var x: float = p.x + cos(a) * r
			var z: float = p.z + sin(a) * r
			var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
			cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(x, gy + 25.0, z))
			var aim := PvSurfaceAim.pick(main, cam)
			var host_kind := str((aim.get("host", {}) as Dictionary).get("kind", ""))
			if bool(aim.get("valid", false)) and not bool(aim.get("pitched", false)) and host_kind == "terrain":
				print("solar-aim debug: aiming at level ground %.0f m from the player" % r)
				return cam
	print("solar-aim debug: no level ground found; using the last spot")
	return cam


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var cam := _level_ground_camera(main)
	var lat0 := float(main.get("latitude"))
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	for lat in [lat0, -33.9]:
		main.set("latitude", lat)
		var equator := SolarAim.equator_azimuth_deg(lat)
		var best := SolarAim.best_tilt_deg(lat)
		var tag := SolarAim.latitude_text(lat)
		# ---- the ground-mount rack: placed for real -------------------------
		PlacedPropService.begin_placement(main, PvArrayBuilder.MODEL_ID, {"record_extra": {"pv_array_spec": {"count": 6,
			"tilt_deg": best}}})
		await tree.process_frame
		PlacedPropService.update_placement_aim(main, cam)
		var g: Node3D = PlacedPropService._ghost_node
		_ok(g != null and absf(_wrap(_face_az(g.global_transform.basis) - equator)) < 1.0,
			"%s rack ghost faces %s (%.0f°)" % [tag, SolarAim.compass_word(equator),
				_face_az(g.global_transform.basis) if g != null else -1.0])
		var hint := PlacedPropService.placement_hint()
		print("solar-aim hint: ", hint)
		_ok(hint.contains("faces " + SolarAim.compass_word(equator)), "%s prompt names the facing" % tag)
		var before := {}
		for r0 in loader.call("placed_prop_records"):
			before[str((r0 as Dictionary).get("id", ""))] = true
		var placed := PlacedPropService.confirm_placement()
		await tree.process_frame
		var rec := {}
		for r in loader.call("placed_prop_records"):
			if str((r as Dictionary).get("model_id", "")) == PvArrayBuilder.MODEL_ID \
					and not before.has(str((r as Dictionary).get("id", ""))):
				rec = r
		var news := []
		for r2 in loader.call("placed_prop_records"):
			if not before.has(str((r2 as Dictionary).get("id", ""))):
				news.append(str((r2 as Dictionary).get("model_id", "")))
		print("solar-aim debug: confirm=%s new records=%s" % [str(placed), str(news)])
		_ok(placed and not rec.is_empty(), "%s rack placed" % tag)
		if not rec.is_empty():
			var o := PvArrayBuilder.orientation_for(float(rec.get("yaw", 0.0)),
				float(PvArrayBuilder.resolve_spec(rec.get("pv_array_spec", {}))["tilt_deg"]))
			_ok(absf(_wrap(float(o["azimuth_deg"]) - equator)) < 1.0 and absf(float(o["tilt_deg"]) - best) < 0.01,
				"%s placed rack faces %.0f° at %.1f° (best %.1f°)" % [tag, float(o["azimuth_deg"]), float(o["tilt_deg"]), best])
			if loader.has_method("delete_prop_by_id"):
				loader.call("delete_prop_by_id", str(rec.get("id", "")))
		await tree.process_frame
		# ---- designed arrays: ground (best tilt on) and a tracker ------------
		for mount in ["ground", "tracker"]:
			var spec := PvLabSpec.default_spec()
			spec["array"]["mount"] = mount
			spec["array"]["site_lat"] = 10.0   # stale: placement must stamp this world's
			PlacedPropService.begin_placement(main, PvLabBuilder.MODEL_ID,
				{"record_extra": {"pvlab_spec": PvLabSpec.to_json_safe(spec), "collision_enabled": true}})
			await tree.process_frame
			PlacedPropService.update_placement_aim(main, cam)
			var aim: Dictionary = PlacedPropService._pv_aim
			var gx: Node3D = PlacedPropService._ghost_node
			var rx: Dictionary = PlacedPropService._placement_prep.get("record_extra", {})
			var arr: Dictionary = PvLabSpec.resolve(rx.get("pvlab_spec", {}))["array"]
			_ok(absf(float(arr["site_lat"]) - lat) < 1e-3, "%s %s design stamped with this latitude" % [tag, mount])
			if bool(aim.get("pitched", false)):
				print("solar-aim note: %s %s aimed at a pitched surface; facing follows the slope" % [tag, mount])
			elif gx == null or not bool(aim.get("valid", false)):
				_ok(false, "%s %s ghost aimed at the ground" % [tag, mount])
			elif mount == "ground":
				_ok(absf(_wrap(_face_az(gx.global_transform.basis) - equator)) < 1.0 and absf(float(arr["tilt_deg"]) - best) < 0.01,
					"%s designed ground array faces %.0f° at %.1f°" % [tag, _face_az(gx.global_transform.basis), float(arr["tilt_deg"])])
			else:
				var axis := gx.global_transform.basis * Vector3(0.0, 0.0, 1.0)
				_ok(absf(axis.x) < 0.02, "%s tracker axis runs north-south (x %.3f)" % [tag, axis.x])
			print("solar-aim hint: ", PlacedPropService.placement_hint())
			PlacedPropService.cancel_placement()
			await tree.process_frame
		# ---- the trough keeps its east-west pivot ----------------------------
		PlacedPropService.begin_placement(main, "csp_trough")
		await tree.process_frame
		PlacedPropService.update_placement_aim(main, cam)
		var gt: Node3D = PlacedPropService._ghost_node
		var model := gt.get_node_or_null("GhostModel") as Node3D if gt != null else null
		_ok(model != null and absf(_wrap(rad_to_deg(gt.global_rotation.y + model.rotation.y)
			- ModelCatalog.forced_yaw_deg("csp_trough"))) < 0.5, "%s trough ghost on its east-west axis" % tag)
		_ok(PlacedPropService.placement_hint().contains("east–west"), "%s trough prompt" % tag)
		PlacedPropService.cancel_placement()
		await tree.process_frame
	main.set("latitude", lat0)
	cam.queue_free()
	print("solar-aim: %s" % ("PASS" if _fails.is_empty() else "FAILED %d" % _fails.size()))
	return {"ok": _fails.is_empty(), "fails": _fails}

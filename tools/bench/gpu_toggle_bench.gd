extends RefCounted

## GPU isolation bench: which render feature or scene layer owns the GPU
## frame? Mount Vernon measured 31 ms of GPU against ~4 ms of script with the
## graph closed (2026-10-18, first_person_bench), at HALF render scale — so no
## CPU work in Push 1 can move that frame; the GPU owner has to be named.
##
## From the saved first-person view, the renderer's measured GPU time is
## sampled with everything as the player left it, then with ONE thing
## switched off at a time and restored: SSIL, SSAO, volumetric fog, glow,
## MSAA, TAA, the sun's shadow, and each scene layer hidden (vegetation,
## placed props, sculpt tiles, buildings, water, painted camps, people, placed
## lights, the ground itself). The baseline is taken again at the end so a
## drift (a bake landing mid-run) shows. Nothing is persisted: the toggles
## are written straight to the viewport / environment / nodes and put back.
##
## Dry run only, sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/bench/gpu_toggle_bench.gd
## Prints `gpubench …` lines: one per toggle with GPU ms, the delta against
## the baseline, render CPU ms and draw calls.

const SETTLE_S := 1.2
const SAMPLE_S := 2.5
const PARK_HOUR := 12.0


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	await tree.process_frame
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var clock: Object = main.get("clock")
	if clock != null:
		clock.set("day_time", PARK_HOUR)
	var vp := main.get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	var we: WorldEnvironment = main.get("environment")
	var env: Environment = we.environment if we != null else null
	if env == null:
		return {"ok": false, "why": "no WorldEnvironment"}
	await _wait(tree, 4.0)
	print("gpubench: window %s · scale_3d %.2f · msaa %d · taa %s · ssao %s · ssil %s · sdfgi %s · vol fog %s (density %.4f) · glow %s · shadow atlas quality %d" % [
		str(vp.size), vp.scaling_3d_scale, int(vp.msaa_3d), str(vp.use_taa),
		str(env.ssao_enabled), str(env.ssil_enabled), str(env.sdfgi_enabled),
		str(env.volumetric_fog_enabled), env.volumetric_fog_density, str(env.glow_enabled),
		int(main.get("graphics_quality"))])

	var base := await _sample(tree, vp)
	_print("baseline", base, base)
	var results := {"baseline": base}
	for name in _toggles(main):
		var st := _apply(main, env, vp, str(name))
		if st.is_empty():
			print("gpubench %-16s skipped (not present)" % str(name))
			continue
		await _wait(tree, SETTLE_S)
		var s := await _sample(tree, vp)
		_restore(main, env, vp, str(name), st)
		_print(str(name), s, base)
		results[str(name)] = s
		await _wait(tree, 0.4)
	# ── Vegetation breakdown: hide one species/tier batch group at a time. ──
	# Batch nodes are "Bulk_<species>_<tier>_<cx>_<cz>" (mesh tiers) and
	# "Bulk_<species>_imp_<cx>_<cz>" (impostors): the group key is the name
	# without its two chunk coordinates. ~70 groups × 2 s: only with
	# `-UserArgs @("--veg-groups")`.
	var groups := _veg_groups(main) if "--veg-groups" in OS.get_cmdline_user_args() else {}
	print("gpubench veg: %d batch groups over %d nodes" % [groups.size(), _veg_node_count(groups)])
	var veg_rows: Array = []
	for key in groups.keys():
		var nodes: Array = groups[key]
		var shown: Array = []
		var inst := 0
		for n in nodes:
			var mmi := n as MultiMeshInstance3D
			if mmi != null and mmi.visible:
				mmi.visible = false
				shown.append(mmi)
				if mmi.multimesh != null:
					inst += mmi.multimesh.visible_instance_count if mmi.multimesh.visible_instance_count >= 0 \
							else mmi.multimesh.instance_count
		if shown.is_empty():
			continue
		await _wait(tree, 0.8)
		var s := await _sample_short(tree, vp)
		for n in shown:
			(n as Node3D).visible = true
		veg_rows.append([float(base["gpu"]) - float(s["gpu"]), str(key), shown.size(), inst, float(s["gpu"])])
		await _wait(tree, 0.3)
	veg_rows.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
	for r in veg_rows:
		print("gpubench veg %-34s saves %6.2f ms (GPU %6.2f) · %3d batches · %6d instances" % [
			str(r[1]), float(r[0]), float(r[4]), int(r[2]), int(r[3])])

	# ── Foliage render-mode experiments. The canopy shaders ship with
	# depth_prepass_alpha: a depth pre-pass AND an alpha pass, cull_disabled,
	# and MSAA resolves every leaf edge in both. Variants, each with a PNG
	# beside the baseline's so the look can be judged, not just the ms:
	#   scissor  — ALPHA_SCISSOR_THRESHOLD, one opaque pass, hard edges;
	#   a2c      — alpha_to_coverage, one opaque pass, MSAA-softened edges;
	#   a2c_scissor — both (coverage inside the cutout).
	_shoot(main, "baseline")
	for name in ["veg_scissor", "veg_a2c", "veg_a2c_scissor", "veg_scissor_msaa_off",
			"veg_a2c_msaa4"]:
		var st := _apply_canopy_variant(main, vp, name)
		if st.is_empty():
			print("gpubench %-16s skipped (no canopy materials)" % name)
			continue
		await _wait(tree, SETTLE_S)
		var s2 := await _sample(tree, vp)
		_shoot(main, name)
		_restore_scissor(vp, st)
		_print(name, s2, base)
		results[name] = s2
		await _wait(tree, 0.4)

	var base2 := await _sample(tree, vp)
	_print("baseline again", base2, base)
	results["baseline_again"] = base2
	return {"ok": true, "results": results}


func _veg_roots(main: Node) -> Array:
	var terrain := main.get_node_or_null("Terrain")
	var out: Array = []
	if terrain == null:
		return out
	for nm in ["Vegetation", "AutoVegetation"]:
		var r := terrain.get_node_or_null(nm)
		if r != null:
			out.append(r)
	return out


func _veg_groups(main: Node) -> Dictionary:
	var groups: Dictionary = {}
	for root in _veg_roots(main):
		for child in (root as Node).get_children():
			if not (child is MultiMeshInstance3D):
				continue
			var nm := String(child.name)
			if not nm.begins_with("Bulk_"):
				continue
			var parts := nm.split("_")
			# Drop the trailing two chunk coordinates.
			var key := "_".join(parts.slice(0, maxi(parts.size() - 2, 1)))
			key = String(root.name) + "/" + key
			var arr: Array = groups.get(key, [])
			arr.append(child)
			groups[key] = arr
	return groups


func _veg_node_count(groups: Dictionary) -> int:
	var n := 0
	for k in groups:
		n += (groups[k] as Array).size()
	return n


## Every canopy ShaderMaterial under the vegetation roots, by object.
func _canopy_materials(main: Node) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for root in _veg_roots(main):
		for child in (root as Node).get_children():
			var mmi := child as MultiMeshInstance3D
			if mmi == null:
				continue
			var mats: Array = []
			if mmi.material_override != null:
				mats.append(mmi.material_override)
			var mesh := mmi.multimesh.mesh if mmi.multimesh != null else null
			if mesh != null:
				for si in mesh.get_surface_count():
					mats.append(mesh.surface_get_material(si))
			for m in mats:
				var sm := m as ShaderMaterial
				if sm == null or sm.shader == null or seen.has(sm.get_instance_id()):
					continue
				var p := sm.shader.resource_path
				if p.ends_with("foliage.gdshader") or p.ends_with("leaf_canopy.gdshader") \
						or p.ends_with("veg_impostor.gdshader"):
					seen[sm.get_instance_id()] = true
					out.append(sm)
	return out


## A copy of a canopy shader with `depth_prepass_alpha` replaced by the
## variant's render mode / alpha writes.
func _variant_shader_for(orig: Shader, cache: Dictionary, scissor: bool, a2c: bool) -> Shader:
	var key := orig.get_instance_id()
	if cache.has(key):
		return cache[key]
	var code := orig.code
	var mode_repl := "alpha_to_coverage" if a2c else ""
	code = code.replace(", depth_prepass_alpha", (", " + mode_repl) if a2c else "")
	code = code.replace("depth_prepass_alpha, ", (mode_repl + ", ") if a2c else "")
	var lines := code.split("\n")
	var out: Array = []
	for ln in lines:
		out.append(ln)
		var s := ln.strip_edges()
		if scissor and (s.begins_with("ALPHA =") or s.begins_with("ALPHA = ")):
			var indent := ln.substr(0, ln.length() - ln.lstrip(" \t").length())
			out.append(indent + "ALPHA_SCISSOR_THRESHOLD = 0.5;")
	var sh := Shader.new()
	sh.code = "\n".join(out)
	cache[key] = sh
	return sh


func _apply_canopy_variant(main: Node, vp: Viewport, name: String) -> Dictionary:
	var mats := _canopy_materials(main)
	if mats.is_empty():
		return {}
	var scissor := name.contains("scissor")
	var a2c := name.contains("a2c")
	var cache: Dictionary = {}
	var restore: Array = []
	for m in mats:
		var sm := m as ShaderMaterial
		restore.append([sm, sm.shader])
		sm.shader = _variant_shader_for(sm.shader, cache, scissor, a2c)
	var st := {"mats": restore, "msaa": vp.msaa_3d}
	if name.ends_with("msaa_off"):
		vp.msaa_3d = Viewport.MSAA_DISABLED
	elif name.ends_with("msaa4"):
		vp.msaa_3d = Viewport.MSAA_4X
	print("gpubench: canopy variant %s on %d materials (%d shaders)" % [name, mats.size(), cache.size()])
	return st


## One PNG of the current frame beside the numbers (user://screenshots is the
## player's real folder through the sandbox junction).
func _shoot(main: Node, name: String) -> void:
	var dir := "user://screenshots/gpubench"
	DirAccess.make_dir_recursive_absolute(dir)
	var img := main.get_viewport().get_texture().get_image()
	if img != null:
		var path := "%s/%s.png" % [dir, name]
		img.save_png(path)
		print("gpubench shot: %s" % path)


func _restore_scissor(vp: Viewport, st: Dictionary) -> void:
	for pair in (st.get("mats", []) as Array):
		var sm := (pair as Array)[0] as ShaderMaterial
		if is_instance_valid(sm):
			sm.shader = (pair as Array)[1] as Shader
	vp.msaa_3d = st["msaa"] as Viewport.MSAA


func _sample_short(tree: SceneTree, vp: Viewport) -> Dictionary:
	var rid := vp.get_viewport_rid()
	var gpu: Array = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1200:
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	gpu.sort()
	return {"gpu": gpu[gpu.size() / 2]}


func _toggles(main: Node) -> Array:
	return ["ssil_off", "ssao_off", "volfog_off", "glow_off", "msaa_off", "taa_off",
		"scale_1.0", "scale_0.5", "sun_shadow_off", "veg_hidden", "props_hidden",
		"tiles_hidden", "buildings_hidden", "water_hidden", "camps_hidden",
		"people_hidden", "lights_hidden", "ground_hidden"]


## Switch one thing off. Returns what to put back ({} = nothing to toggle).
func _apply(main: Node, env: Environment, vp: Viewport, name: String) -> Dictionary:
	match name:
		"ssil_off":
			if not env.ssil_enabled:
				return {}
			var st := {"user": main.get("ssil_user_enabled")}
			main.set("ssil_user_enabled", false)
			main.call("_apply_advanced_rendering_toggles")
			return st
		"ssao_off":
			if not env.ssao_enabled:
				return {}
			var st := {"user": main.get("ssao_user_enabled")}
			main.set("ssao_user_enabled", false)
			main.call("_apply_advanced_rendering_toggles")
			return st
		"volfog_off":
			if not env.volumetric_fog_enabled:
				return {}
			var st := {"user": main.get("volumetric_fog_user_enabled"),
				"god": main.get("god_rays_enabled"), "env": env.volumetric_fog_enabled}
			main.set("volumetric_fog_user_enabled", false)
			main.set("god_rays_enabled", false)
			main.call("_apply_advanced_rendering_toggles")
			env.volumetric_fog_enabled = false
			return st
		"glow_off":
			if not env.glow_enabled:
				return {}
			var st := {"user": main.get("glow_user_enabled")}
			main.set("glow_user_enabled", false)
			env.glow_enabled = false
			return st
		"msaa_off":
			if vp.msaa_3d == Viewport.MSAA_DISABLED:
				return {}
			var st := {"v": vp.msaa_3d}
			vp.msaa_3d = Viewport.MSAA_DISABLED
			return st
		"taa_off":
			if not vp.use_taa:
				return {}
			vp.use_taa = false
			return {"v": true}
		"scale_1.0":
			if is_equal_approx(vp.scaling_3d_scale, 1.0):
				return {}
			var st := {"v": vp.scaling_3d_scale}
			vp.scaling_3d_scale = 1.0
			return st
		"scale_0.5":
			if is_equal_approx(vp.scaling_3d_scale, 0.5):
				return {}
			var st := {"v": vp.scaling_3d_scale}
			vp.scaling_3d_scale = 0.5
			return st
		"sun_shadow_off":
			var sun: Node = main.get("sun")
			if sun == null or not (sun as DirectionalLight3D).shadow_enabled:
				return {}
			(sun as DirectionalLight3D).shadow_enabled = false
			return {"v": true}
		_:
			return _hide(main, name)


func _restore(main: Node, env: Environment, vp: Viewport, name: String, st: Dictionary) -> void:
	match name:
		"ssil_off":
			main.set("ssil_user_enabled", st["user"])
			main.call("_apply_advanced_rendering_toggles")
		"ssao_off":
			main.set("ssao_user_enabled", st["user"])
			main.call("_apply_advanced_rendering_toggles")
		"volfog_off":
			main.set("volumetric_fog_user_enabled", st["user"])
			main.set("god_rays_enabled", st["god"])
			main.call("_apply_advanced_rendering_toggles")
			env.volumetric_fog_enabled = bool(st["env"])
		"glow_off":
			main.set("glow_user_enabled", st["user"])
			env.glow_enabled = bool(st["user"])
		"msaa_off":
			vp.msaa_3d = st["v"] as Viewport.MSAA
		"taa_off":
			vp.use_taa = true
		"scale_1.0", "scale_0.5":
			vp.scaling_3d_scale = float(st["v"])
		"sun_shadow_off":
			(main.get("sun") as DirectionalLight3D).shadow_enabled = true
		_:
			for n in (st.get("nodes", []) as Array):
				if is_instance_valid(n):
					(n as Node3D).visible = true


## Scene layers by node name under Terrain / Main.
func _layer_nodes(main: Node, name: String) -> Array:
	var terrain := main.get_node_or_null("Terrain")
	var out: Array = []
	var names: Array = []
	var holder: Node = terrain
	match name:
		"veg_hidden": names = ["Vegetation", "AutoVegetation", "Deadwood", "VegLeafFall"]
		"props_hidden": names = ["PlacedProps"]
		"tiles_hidden": names = ["HeightField"]
		"buildings_hidden": names = ["Buildings", "BuildingsCustom"]
		"water_hidden": names = ["Water", "WaterNetwork", "WaterBuried", "WaterCulvertMouths"]
		"camps_hidden": names = ["PaintedCamps", "Camps"]
		"ground_hidden": names = ["Ground", "DetailGround"]
		"lights_hidden":
			holder = main
			names = ["PlacedLights"]
		"people_hidden":
			holder = main
			names = ["NpcPopulationHost"]
			for c in main.get_children():
				if c is Node3D and (c.get_script() != null
						and str((c.get_script() as Script).resource_path).ends_with("crowd_renderer.gd")):
					out.append(c)
	if holder == null:
		return out
	for n in names:
		var node := holder.get_node_or_null(str(n))
		if node is Node3D:
			out.append(node)
	return out


func _hide(main: Node, name: String) -> Dictionary:
	var nodes: Array = []
	for n in _layer_nodes(main, name):
		if (n as Node3D).visible:
			(n as Node3D).visible = false
			nodes.append(n)
	if nodes.is_empty():
		return {}
	return {"nodes": nodes}


func _sample(tree: SceneTree, vp: Viewport) -> Dictionary:
	var rid := vp.get_viewport_rid()
	var gpu: Array = []
	var cpu: Array = []
	var draws := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(SAMPLE_S * 1000.0):
		await tree.process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid)
			+ RenderingServer.get_frame_setup_time_cpu())
		draws += float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		frames += 1
	gpu.sort()
	cpu.sort()
	return {"gpu": gpu[gpu.size() / 2], "gpu_p90": gpu[int(gpu.size() * 0.9)],
		"cpu": cpu[cpu.size() / 2], "draws": draws / maxf(float(frames), 1.0),
		"fps": float(frames) / SAMPLE_S}


func _print(name: String, s: Dictionary, base: Dictionary) -> void:
	print("gpubench %-16s GPU %6.2f ms (p90 %6.2f, Δ %+6.2f) · render CPU %5.2f ms · %5d draw calls · %4.0f fps" % [
		name, float(s["gpu"]), float(s["gpu_p90"]), float(s["gpu"]) - float(base["gpu"]),
		float(s["cpu"]), int(s["draws"]), float(s["fps"])])


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s, true, false, true).timeout

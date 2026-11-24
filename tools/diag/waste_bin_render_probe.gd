extends RefCounted

## NOT a selftest — the diagnostic behind "the bin's pile draws nothing"
## (plans/FOOD_WASTE_REALISM_PLAN.md Phase 8).
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/waste_bin_render_probe.gd -Label wb_probe -Timeout 600
## Places a bin, fills its ledger, DUMPS everything about the pile
## MultiMeshes (tree, visibility, transforms, ranges, buffer), then stands
## a plain MeshInstance3D of the same bottle mesh plus two standalone
## replica MultiMeshes beside the bin, so "the mesh is wrong", "the
## MultiMesh recipe is wrong" and "the prop subtree gates it" all read
## apart. Shots front / top.
##
## WHAT IT FOUND (2026-11-23): nothing was ever wrong with the
## MultiMeshes — the bin's kind STRIPE was a single BoxMesh spanning the
## whole plan at rim height, and its top face capped the opening like a
## lid, hiding the entire pile below it. From outside it read as a band.
## The stripe is a hollow four-box frame now (WasteBinBuilder). Keep this
## probe: it separates mesh / recipe / subtree for any future invisible
## MultiMesh under a prop.

var _dir := "user://screenshots/wb_probe"


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var gv := ServiceLocator.graph()
	var engine = gv.get("_resource_flow")
	main.set("time_scale", 0.0)
	var h0 := float(main.call("get_absolute_hours"))
	var player: Node3D = main.get_node_or_null("Player")
	var px := player.global_position.x if player != null else 0.0
	var pz := player.global_position.z if player != null else 0.0
	var res := PlacedPropService.place_model_at_xz(main, "waste_bin", px + 5.0, pz + 2.0,
		{"bin_spec": {"kind": "pet_waste"}})
	var pid := str(res.get("prop_id", ""))
	for _i in 6:
		await tree.process_frame
	var rec := PlacedPropService.get_prop_record(main, pid)
	var gid := str(rec.get("graph_item_id", ""))
	var led = engine.call("ensure_item_ledger", gid)
	led.call("record", h0 - 0.5, "pet_bottle_500", 60, 60.0 * 0.024)
	await tree.create_timer(0.8).timeout

	var prop := PlacedPropRuntime.find_by_prop_id(main, pid)
	var rt: Node = prop.get_node_or_null("WasteBinRuntime")
	print("wb-probe prop=%s at %s rt=%s" % [prop, str((prop as Node3D).global_position), rt])
	# Walk the whole prop subtree: every visual node with its state.
	var stack: Array = [prop]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D or n is MultiMeshInstance3D:
			var gi := n as GeometryInstance3D
			var line := "wb-probe node=%s class=%s visible=%s vis_in_tree=%s layers=%d range=[%.1f..%.1f] gpos=%s" % [
				n.get_path(), n.get_class(), str(gi.visible), str(gi.is_visible_in_tree()),
				gi.layers, gi.visibility_range_begin, gi.visibility_range_end,
				str(gi.global_position)]
			if n is MultiMeshInstance3D:
				var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
				line += " mm_count=%d mesh=%s surf=%d custom_aabb=%s local_aabb=%s buf0=%s" % [
					mm.instance_count, str(mm.mesh != null),
					mm.mesh.get_surface_count() if mm.mesh != null else -1,
					str((n as MultiMeshInstance3D).custom_aabb), str(gi.get_aabb()),
					str(mm.buffer.slice(0, 12))]
			print(line)
	# A plain MeshInstance3D of the same bottle beside the bin, 10x size.
	var base: Vector3 = (prop as Node3D).global_position
	var ref := MeshInstance3D.new()
	ref.mesh = WasteItemMeshes.mesh("pet_bottle")
	ref.scale = Vector3(10, 10, 10)
	main.add_child(ref)
	ref.global_position = base + Vector3(-1.5, 1.2, 0)
	# Standalone replica MultiMeshes beside the bin: A bare, B the
	# runtime's exact recipe (hidden zero-basis slots + custom_aabb).
	var mma := MultiMesh.new()
	mma.transform_format = MultiMesh.TRANSFORM_3D
	mma.mesh = WasteItemMeshes.mesh("pet_bottle")
	mma.instance_count = 5
	for i in 5:
		mma.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(i * 0.2, 0.0, 0.0)))
	var na := MultiMeshInstance3D.new()
	na.multimesh = mma
	main.add_child(na)
	na.global_position = base + Vector3(1.2, 1.2, 0)
	var mmb := MultiMesh.new()
	mmb.transform_format = MultiMesh.TRANSFORM_3D
	mmb.mesh = WasteItemMeshes.mesh("pet_bottle")
	mmb.instance_count = 256
	var hid := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -50, 0))
	for i in 256:
		mmb.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(fmod(i * 0.07, 0.6), 0.0, 0.1 + 0.05 * (i / 10))) if i < 5 else hid)
	var nb := MultiMeshInstance3D.new()
	nb.multimesh = mmb
	nb.custom_aabb = AABB(Vector3(-0.61, 0, -0.73), Vector3(1.22, 3.0, 1.46))
	main.add_child(nb)
	nb.global_position = base + Vector3(1.2, 1.8, 0)
	# C = the same bare MMI added directly under the prop's ModelRoot.
	var model_root := prop.get_node_or_null("ModelRoot") as Node3D
	var mmc := MultiMesh.new()
	mmc.transform_format = MultiMesh.TRANSFORM_3D
	mmc.mesh = WasteItemMeshes.mesh("pet_bottle")
	mmc.instance_count = 5
	for i in 5:
		mmc.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(i * 0.1 - 0.2, 1.4, 0.0)))
	var nc := MultiMeshInstance3D.new()
	nc.name = "ProbeC"
	nc.multimesh = mmc
	model_root.add_child(nc)

	var cam := main.get_viewport().get_camera_3d()
	var at: Vector3 = base + Vector3(0, 0.7, 0)
	cam.look_at_from_position(at + Vector3(2.0, 1.4, 1.6), at, Vector3.UP)
	await tree.create_timer(0.8).timeout
	main.get_viewport().get_texture().get_image().save_png("%s/00_probe_front.png" % _dir)
	cam.look_at_from_position(at + Vector3(0.1, 2.6, 0.1), at, Vector3.UP)
	await tree.create_timer(0.6).timeout
	main.get_viewport().get_texture().get_image().save_png("%s/01_probe_top.png" % _dir)
	ref.queue_free()
	na.queue_free()
	nb.queue_free()
	nc.queue_free()
	print("wb-probe done")
	return {"ok": true}

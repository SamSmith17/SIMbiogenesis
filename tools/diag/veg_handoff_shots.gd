extends RefCounted

## Sandbox, read-only: the same forest views as tools/bench/veg_spots_bench.gd
## saved as PNGs (noon, clock held, UI hidden), for before / after pairs of a
## vegetation change.
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/diag/veg_handoff_shots.gd -Label <dir>

const SPOTS := 16
const SHOTS := 10
const PARK_HOUR := 12.0
const CLAIM := "veg_handoff_shots"


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var loader: Node = main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var dir := "user://screenshots/%s" % str(harness.get("_shots_label"))
	DirAccess.make_dir_recursive_absolute(dir)
	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	var trees := PackedVector3Array()
	for _w in 40:
		for _i in 15:
			await tree.process_frame
		trees = _tree_positions(main)
		if trees.size() > 0:
			break
	if trees.is_empty():
		return {"ok": false, "why": "no tree batches"}
	main.set("time_scale", 0.0)
	main.set("day_time", PARK_HOUR)
	var baker: Node = loader.get("_impostor_baker")
	var waited := 0.0
	while waited < 90.0:
		await tree.create_timer(0.5).timeout
		waited += 0.5
		var busy := baker != null and bool(baker.call("is_busy"))
		if not busy and not bool(loader.get("_impostor_rebuild_pending")) and waited > 3.0:
			break
	var hidden: Array = []
	for ch in main.get_children():
		if ch is CanvasLayer and (ch as CanvasLayer).visible:
			(ch as CanvasLayer).visible = false
			hidden.append(ch)
	var vp := main.get_viewport()
	var player_cam := vp.get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = player_cam.fov if player_cam != null else 75.0
	cam.near = player_cam.near if player_cam != null else 0.05
	cam.far = player_cam.far if player_cam != null else 4000.0
	if player_cam != null:
		cam.environment = player_cam.environment
		cam.attributes = player_cam.attributes
		cam.cull_mask = player_cam.cull_mask
	main.add_child(cam)
	main.call("push_camera_claim", CLAIM, {"camera_id": cam.get_instance_id()})
	var stride := maxi(1, trees.size() / SPOTS)
	var k := 0
	var view := 0
	var saved: Array = []
	while k < trees.size() and view < SHOTS:
		var p := trees[k]
		k += stride
		var x := p.x + 3.0
		var z := p.z + 3.0
		var gy := float(loader.call("ground_height_at", x, z))
		for turn in 2:
			if view >= SHOTS:
				break
			var yaw := float(view) * 2.399 + float(turn) * PI
			var fwd := Vector3(sin(yaw), -0.07, cos(yaw)).normalized()
			cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP),
				Vector3(x, gy + 1.7, z))
			for _i in 40:
				await tree.process_frame
			await RenderingServer.frame_post_draw
			var path := "%s/view_%02d.png" % [dir, view]
			vp.get_texture().get_image().save_png(path)
			saved.append(path)
			print("veg_handoff_shots: %s" % path)
			view += 1
	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	for ch in hidden:
		(ch as CanvasLayer).visible = true
	return {"ok": true, "shots": saved.size()}


func _tree_positions(main: Node) -> PackedVector3Array:
	var seen := {}
	_collect(main, seen)
	var keys := seen.keys()
	keys.sort()
	var out := PackedVector3Array()
	for key in keys:
		out.append(seen[key])
	return out


func _collect(n: Node, seen: Dictionary) -> void:
	for ch in n.get_children():
		_collect(ch, seen)
	if not (n is MultiMeshInstance3D) or not n.has_meta(&"veg_species"):
		return
	var mi := n as MultiMeshInstance3D
	if mi.multimesh == null:
		return
	var fam := VegSpeciesCatalog.mesh_family(str(mi.get_meta(&"veg_species")))
	if fam != "pine" and fam != "deciduous":
		return
	var xf := mi.global_transform
	for i in mi.multimesh.instance_count:
		var p := xf * mi.multimesh.get_instance_transform(i).origin
		seen[Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0))] = p

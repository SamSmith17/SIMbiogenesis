class_name GreenhouseWorld
extends RefCounted

## A placed greenhouse in the world: its record follows its design. Run on
## placement and after the designer's Apply (`sync`):
##  - the parts inside it (GreenhouseParts: beds, FarmBot beds, light racks)
##    are their own props, created / updated / removed to match the design,
##    each mounted on the shell (`mount_host {kind, id, local, owned: true}`)
##    so moving, packing or deleting the greenhouse carries them;
##  - a sunk or bermed house gets its earthworks (the opening, berms, a ramp
##    down to the door);
##  - walk_in, so people path in through the door.
## The graph side (one compound with the parts inside) is GreenhouseGraph.

const SINK_RAMP_SLOPE := 3.5


static func is_greenhouse(rec: Dictionary) -> bool:
	return str(rec.get("model_id", "")) == GreenhouseBuilder.MODEL_ID


static func spec_of(rec: Dictionary) -> Dictionary:
	var v: Variant = rec.get(GreenhouseSpec.KEY, {})
	return v if v is Dictionary else {}


## The props mounted on `host_id` that a greenhouse owns: {gh_part: record}.
static func parts_of(main: Node, host_id: String) -> Dictionary:
	var out := {}
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null:
		return out
	for r in layer.props:
		var rec: Dictionary = r
		var mh: Variant = rec.get("mount_host")
		if mh is Dictionary and str((mh as Dictionary).get("id", "")) == host_id \
				and not str(rec.get(GreenhouseParts.KEY, "")).is_empty():
			out[str(rec[GreenhouseParts.KEY])] = rec
	return out


static func sync(main: Node, prop_id: String) -> void:
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty() or not is_greenhouse(rec):
		return
	var d := GreenhouseDesign.solve(spec_of(rec))
	var patch := {"walk_in": true}
	var ew := earthworks(d)
	if ew.is_empty():
		if rec.has(StructureEarthworks.KEY):
			patch[StructureEarthworks.KEY] = null
	else:
		patch[StructureEarthworks.KEY] = ew
	PlacedPropService.update_prop_record(main, prop_id, patch, true)
	rec = PlacedPropService.get_prop_record(main, prop_id)
	sync_parts(main, prop_id, d, rec)
	sync_graph(main, prop_id, d)


## The house's one graph node (GreenhouseGraph), its beds and lights bound to
## their props. A packed house keeps its node (packed_3d stops it growing).
static func sync_graph(main: Node, prop_id: String, d: Dictionary = {}) -> String:
	var sgv := ServiceLocator.graph()
	if sgv == null or not sgv.has_method("sync_greenhouse_system"):
		return ""
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return ""
	if d.is_empty():
		d = GreenhouseDesign.solve(spec_of(rec))
	var parts := {}
	var pr := parts_of(main, prop_id)
	for k in pr:
		parts[k] = str((pr[k] as Dictionary).get("id", ""))
	var y := float(rec.get("ground_y", 0.0))
	var cid := str(sgv.call("sync_greenhouse_system", prop_id, d, parts,
		Vector3(float(rec.get("x", 0.0)), y, float(rec.get("z", 0.0))), float(rec.get("yaw", 0.0))))
	if cid.is_empty():
		return ""
	# Each prop knows its node, so packing a bed (with the house) stops it.
	var links := {prop_id: cid}
	var by_role := GreenhouseGraph.children_by_role(sgv.get("model"), cid)
	for c in by_role.get("bed", []):
		var sp: Dictionary = (c as Dictionary).get("specs", {})
		var pid := str(sp.get("bound_prop_id", ""))
		if not pid.is_empty():
			links[pid] = str((c as Dictionary)["id"])
	for c in by_role.get("lights", []):
		var sp2: Dictionary = (c as Dictionary).get("specs", {})
		var pid2 := str(sp2.get("bound_prop_id", ""))
		if not pid2.is_empty():
			links[pid2] = str((c as Dictionary)["id"])
	for pid3 in links:
		var r3 := PlacedPropService.get_prop_record(main, str(pid3))
		if not r3.is_empty() and str(r3.get("graph_item_id", "")) != str(links[pid3]):
			PlacedPropService.update_prop_record(main, str(pid3), {"graph_item_id": str(links[pid3])}, false)
	return cid


## The earthworks of a sunk or bermed house ({} when it stands on grade).
static func earthworks(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var sink := float(s["ground"]["sink_m"])
	var berm := str(s["ground"]["berm"])
	if sink <= 0.01 and berm == "none":
		return {}
	var fr: Dictionary = d["frame"]
	var hl := float(s["length_m"]) * 0.5
	var hw := float(s["width_m"]) * 0.5
	if str(fr["form"]) == "dome":
		hl = float(fr["floor"]["r"])
		hw = hl
	var sm := {"sink_m": sink, "rect": [-hl, -hw, hl, hw], "hole": sink > 0.01, "floor_y": 0.0,
		"roof_y": float(fr["ridge_h_m"]), "slab": false, "walls": false, "lights": false}
	var bh := float(s["eave_h_m"]) if str(fr["form"]) != "dome" else 0.8
	var berms := {}
	if berm != "none":
		berms["-z"] = bh
		if berm == "three":
			if str(fr["form"]) == "dome":
				berms["-x"] = bh
				berms["+x"] = bh
			else:
				berms["-x"] = bh
	sm["berm"] = berms
	if sink > 0.01:
		var door: Dictionary = (fr["doors"] as Array)[0]
		var dn: Vector3 = door["normal"]
		var side := "+x" if dn.x > 0.5 else ("-x" if dn.x < -0.5 else ("+z" if dn.z > 0.0 else "-z"))
		sm["daylight"] = side
		sm["cut_w"] = float(door["w_m"]) + 0.6
		sm["ramp_len"] = sink * SINK_RAMP_SLOPE
		sm["ramp_w"] = float(door["w_m"]) + 0.3
	return StructureEarthworks.from_simple(sm)


## Create, update or remove the props inside to match the design.
static func sync_parts(main: Node, prop_id: String, d: Dictionary, host_rec: Dictionary) -> void:
	var have := parts_of(main, prop_id)
	var want := GreenhouseParts.parts(d)
	var host_xf := PvSurfaceAim.record_xf(main, host_rec)
	var keep := {}
	var packed := bool(host_rec.get("packed", false))
	for p in want:
		var pd: Dictionary = p
		var key := str(pd["part"])
		keep[key] = true
		var local := Transform3D(Basis(Vector3.UP, deg_to_rad(float(pd["yaw_deg"]))),
			Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"])))
		var xf := host_xf * local
		var mid := str(pd["model_id"])
		var mount := {"kind": "prop", "id": prop_id, "local": PlacedPropService._xf_to_array(local), "owned": true}
		var extra: Dictionary = (pd["extra"] as Dictionary).duplicate(true)
		extra[GreenhouseParts.KEY] = key
		extra["mount_host"] = mount
		extra["label"] = str(pd["label"])
		extra["collision_enabled"] = mid != GrowLightRack.MODEL_ID
		if packed:
			extra["packed"] = true
		var pose := PvSurfaceAim.record_patch_for(main, mid, xf)
		if have.has(key) and str((have[key] as Dictionary).get("model_id", "")) == mid:
			var old: Dictionary = have[key]
			var upd := extra.duplicate(true)
			for k in pose:
				upd[k] = pose[k]
			# Keep the bed's planting hour (and the graph binding).
			upd.erase("packed")
			PlacedPropService.update_prop_record(main, str(old["id"]), upd, true)
			continue
		if have.has(key):
			_delete(main, str((have[key] as Dictionary)["id"]))
		if mid == GrowBed.MODEL_ID:
			var gb: Dictionary = extra["grow_bed_spec"]
			gb["plant_abs_h"] = _now_h(main)
		var res := PlacedPropService.place_model_at_xz(main, mid, float(pose["x"]), float(pose["z"]), extra)
		if bool(res.get("ok", false)):
			PlacedPropService.update_prop_record(main, str(res["prop_id"]), {"y_offset": pose["y_offset"],
				"yaw": pose["yaw"], "pitch": pose["pitch"], "roll": pose["roll"]}, true)
	for key2 in have:
		if not keep.has(key2):
			_delete(main, str((have[key2] as Dictionary)["id"]))


static func _delete(main: Node, pid: String) -> void:
	if pid.is_empty():
		return
	var loader := main.find_child("TerrainLoader", true, false) if main != null else null
	if loader != null and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pid)


static func _now_h(main: Node) -> float:
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	return 0.0

class_name VehicleCargo
extends RefCounted

## A living vehicle's cargo bay, as the packing code sees a container: the
## largest clear floor rectangle the interior leaves (nothing standing on it),
## the full inside height over it, the biggest door it is loaded through and
## the payload left — a ContainerCatalog-shaped entry, so PackSolver and
## ContainerCatalog.fits_through_door work on it unchanged. Kits are stowed in
## it (`spawn_into`, the UnpackScenario contract: crates `packed`, `stowed_in`
## the host, an unload rank and a staging slot outside the door) and ride
## along with it (`stow_local` on each crate, `place_stowed`). The same rules
## serve a shipping container (`host_bay`, `door_xz`). Pure.
##
## The bay's solver frame (PackSolver: x across, y up, z the load length with
## the DOOR at high z) is laid into the vehicle: through a rear door the length
## runs back (+Z); through a side door only, it runs across to the curb side
## (+X). `frame` = {origin (the nose corner on the floor), x_axis, z_axis},
## vehicle-local.

const CELL_M := 0.1
## Smallest floor worth calling a bay.
const MIN_AREA_M2 := 0.5


## Which floor cells are clear (1) of anything standing on the floor.
static func occupancy(d: Dictionary) -> Dictionary:
	var house: Dictionary = d["house"]
	var hw := float(house["w"])
	var hl := float(house["len"])
	var nx := maxi(int(floor(hw / CELL_M)), 1)
	var nz := maxi(int(floor(hl / CELL_M)), 1)
	var free := PackedByteArray()
	free.resize(nx * nz)
	free.fill(1)
	var z0 := float(house["z0"])
	for e in d.get("interior", []):
		var el: Dictionary = e
		if not VehicleInterior.blocks_floor(d, el):
			continue
		var ax0 := int(floor((float(el["x"]) - float(el["fx"]) * 0.5 + hw * 0.5) / CELL_M))
		var ax1 := int(ceil((float(el["x"]) + float(el["fx"]) * 0.5 + hw * 0.5) / CELL_M))
		var az0 := int(floor((float(el["z"]) - float(el["fz"]) * 0.5 - z0) / CELL_M))
		var az1 := int(ceil((float(el["z"]) + float(el["fz"]) * 0.5 - z0) / CELL_M))
		for iz in range(maxi(az0, 0), mini(az1, nz)):
			for ix in range(maxi(ax0, 0), mini(ax1, nx)):
				free[iz * nx + ix] = 0
	return {"free": free, "nx": nx, "nz": nz}


## The largest clear rectangle (histogram method): {ix0, ix1, iz0, iz1} in
## cells (exclusive ends), {} when none.
static func largest_rect(free: PackedByteArray, nx: int, nz: int) -> Dictionary:
	var h := PackedInt32Array()
	h.resize(nx)
	var best := 0
	var out := {}
	for iz in nz:
		for ix in nx:
			h[ix] = h[ix] + 1 if free[iz * nx + ix] == 1 else 0
		var stack: Array = []
		for ix in nx + 1:
			var cur := h[ix] if ix < nx else 0
			var start := ix
			while not stack.is_empty() and int((stack.back() as Array)[1]) >= cur:
				var top: Array = stack.pop_back()
				var area := int(top[1]) * (ix - int(top[0]))
				if area > best:
					best = area
					out = {"ix0": int(top[0]), "ix1": ix, "iz0": iz - int(top[1]) + 1, "iz1": iz + 1}
				start = int(top[0])
			stack.append([start, cur])
	return out


## The bay as a ContainerCatalog-shaped entry, {} when there is no clear floor
## or no door to load it through.
static func bay(d: Dictionary) -> Dictionary:
	var cargo: Dictionary = d.get("cargo", {})
	var doors: Array = cargo.get("doors", [])
	if doors.is_empty():
		return {}
	var occ := occupancy(d)
	var r := largest_rect(occ["free"], int(occ["nx"]), int(occ["nz"]))
	if r.is_empty():
		return {}
	var house: Dictionary = d["house"]
	var hw := float(house["w"])
	var x0 := -hw * 0.5 + float(r["ix0"]) * CELL_M
	var x1 := -hw * 0.5 + float(r["ix1"]) * CELL_M
	var z0 := float(house["z0"]) + float(r["iz0"]) * CELL_M
	var z1 := float(house["z0"]) + float(r["iz1"]) * CELL_M
	if (x1 - x0) * (z1 - z0) < MIN_AREA_M2:
		return {}
	var door: Dictionary = {}
	for dr in doors:
		if str((dr as Dictionary)["where"]) == "rear":
			door = dr
	var rear := not door.is_empty()
	if not rear:
		door = doors[0]
	var fy := float(house["floor_y"])
	var frame := {}
	var interior := {}
	if rear:
		frame = {"origin": Vector3(x0, fy, z0), "x_axis": Vector3(1, 0, 0), "z_axis": Vector3(0, 0, 1)}
		interior = {"l_m": z1 - z0, "w_m": x1 - x0, "h_m": float(house["height"]) - 0.05}
	else:
		frame = {"origin": Vector3(x0, fy, z0), "x_axis": Vector3(0, 0, 1), "z_axis": Vector3(1, 0, 0)}
		interior = {"l_m": x1 - x0, "w_m": z1 - z0, "h_m": float(house["height"]) - 0.05}
	return {"id": "vehicle_bay", "label": "%s cargo bay" % str(d.get("name", "Vehicle")), "icon": "🚐",
		"kind": "vehicle", "interior": interior,
		"door": {"w_m": float(door["w_m"]), "h_m": float(door["h_m"])}, "door_where": str(door["where"]),
		"payload_kg": maxf(float(d.get("payload_kg", 0.0)), 0.0), "frame": frame,
		"rect": {"x0": x0, "x1": x1, "z0": z0, "z1": z1}, "seats": int(d.get("seats", 0))}


## A point in the bay's solver frame -> vehicle-local.
static func bay_to_local(b: Dictionary, p: Vector3) -> Vector3:
	var f: Dictionary = b["frame"]
	return (f["origin"] as Vector3) + (f["x_axis"] as Vector3) * p.x + Vector3.UP * p.y + (f["z_axis"] as Vector3) * p.z


## A vehicle-local point -> world xz for a record standing at (x, z) with yaw
## (degrees).
static func local_to_world_xz(rec: Dictionary, local: Vector3) -> Vector2:
	return VehicleTow.world_xz(local, Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))),
		deg_to_rad(float(rec.get("yaw", 0.0))))


## Where a crew stands to load or unload: just outside the bay's door (world xz),
## and the outward direction.
static func door_outside(d: Dictionary, rec: Dictionary) -> Dictionary:
	var b := bay(d)
	if b.is_empty():
		return {}
	var hw := float((d["house"] as Dictionary)["w"]) * 0.5
	var local := Vector3.ZERO
	var out_dir := Vector3.ZERO
	if str(b["door_where"]) == "rear":
		local = Vector3(0, 0, float(d["half_len"]) + 0.6)
		out_dir = Vector3(0, 0, 1)
	else:
		var r: Dictionary = b["rect"]
		local = Vector3(hw + 0.8, 0, (float(r["z0"]) + float(r["z1"])) * 0.5)
		out_dir = Vector3(1, 0, 0)
	var p := local_to_world_xz(rec, local)
	var q := local_to_world_xz(rec, local + out_dir)
	return {"x": p.x, "z": p.y, "out": (q - p).normalized()}


## --- cargo hosts: a shipping container or a living vehicle, one set of rules --
##
## Both are placed records whose LOCAL frame is VehicleTow.world_xz's (local +X
## = the record's right, local +Z = behind it): a container's door end is its
## local +Z, a vehicle's rear door its local +Z too. A host's bay carries the
## solver frame in that local frame, so stowing, riding, unloading and
## re-stowing are one code path for both.

## How far outside a container's doors the crew stands.
const CONTAINER_DOOR_OUT_M := 1.0
## Staging: the first row's near edge this far past the door, rows a crate
## long plus an aisle apart, two columns an aisle apart.
const STAGE_GAP_M := 2.5
const STAGE_AISLE_M := 1.2


static func is_container(rec: Dictionary) -> bool:
	return str(rec.get("model_id", "")) == "cargo_container"


static func is_host(rec: Dictionary) -> bool:
	return is_container(rec) or VehicleBuilder.handles(str(rec.get("model_id", "")))


## A container record's catalog entry ({} when it is not one).
static func container_entry(rec: Dictionary) -> Dictionary:
	if not is_container(rec):
		return {}
	var spec: Variant = rec.get("container_spec", {})
	var cid := str((spec as Dictionary).get("container_id", "container_20")) if spec is Dictionary else "container_20"
	return ContainerCatalog.find(cid)


## Any host's bay: the ContainerCatalog-shaped entry with its solver `frame`
## (host-local) and `door_where`. {} when the record holds no cargo.
static func host_bay(rec: Dictionary) -> Dictionary:
	if is_container(rec):
		var e := container_entry(rec)
		if e.is_empty():
			return {}
		var it: Dictionary = e.get("interior", {})
		var b := e.duplicate(true)
		b["frame"] = {"origin": Vector3(-float(it.get("w_m", 0.0)) * 0.5, 0.0, -float(it.get("l_m", 0.0)) * 0.5),
			"x_axis": Vector3(1, 0, 0), "z_axis": Vector3(0, 0, 1)}
		b["door_where"] = "rear"
		return b
	if VehicleBuilder.handles(str(rec.get("model_id", ""))):
		return bay(VehicleDesign.solve(VehicleBuilder.spec_for_record(rec)))
	return {}


## THE door rule: where a crew stands to load or unload any host (world xz)
## and the outward direction. {x, z, out: Vector2}, {} without a door.
static func door_xz(rec: Dictionary) -> Dictionary:
	if is_container(rec):
		var e := container_entry(rec)
		var ext: Dictionary = e.get("exterior", e.get("interior", {}))
		var local := Vector3(0, 0, float(ext.get("l_m", 6.0)) * 0.5 + CONTAINER_DOOR_OUT_M)
		var p := local_to_world_xz(rec, local)
		var q := local_to_world_xz(rec, local + Vector3(0, 0, 1))
		return {"x": p.x, "z": p.y, "out": (q - p).normalized()}
	if VehicleBuilder.handles(str(rec.get("model_id", ""))):
		return door_outside(VehicleDesign.solve(VehicleBuilder.spec_for_record(rec)), rec)
	return {}


## Whether a host can take or give cargo at `abs_h`: not packed, and a vehicle
## standing in its spot (not away or on the road). NAN = don't ask the clock.
## A towed trailer drives with its tow vehicle: pass that record as
## `drive_rec` (the one whose arrival / departure moves it).
static func host_ready(rec: Dictionary, abs_h: float = NAN, drive_rec: Dictionary = {}) -> bool:
	if bool(rec.get("packed", false)):
		return false
	if is_container(rec) or is_nan(abs_h):
		return true
	return VehicleDrive.parked_at(drive_rec if not drive_rec.is_empty() else rec, abs_h)


## The nearest cargo host's door to `pos` within `reach` among placed records:
## {x, z, host_id} or {}. A vehicle away, on the road or packed is no host
## (with `abs_h` given).
static func door_near(records: Array, pos: Vector2, reach: float, abs_h: float = NAN) -> Dictionary:
	var best_d := reach
	var out := {}
	var by_id := {}
	if not is_nan(abs_h):
		for r0 in records:
			by_id[str((r0 as Dictionary).get("id", ""))] = r0
	for r in records:
		var rec: Dictionary = r
		if not is_host(rec):
			continue
		var tow_id := str(rec.get("hitched_to", ""))
		if not host_ready(rec, abs_h, by_id.get(tow_id, {}) if not tow_id.is_empty() else {}):
			continue
		var dist := pos.distance_to(Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))))
		if dist >= best_d:
			continue
		if not is_container(rec) and host_bay(rec).is_empty():
			continue
		var dd := door_xz(rec)
		if dd.is_empty():
			continue
		best_d = dist
		out = {"x": float(dd["x"]), "z": float(dd["z"]), "host_id": str(rec.get("id", ""))}
	return out


## The staging slot for unload rank `rank` outside a door ({x, z, out}): two
## columns, rows a crate long plus an aisle apart. `span` = the largest crate's
## footprint (across, along).
static func staging_xz(door: Dictionary, rank: int, span: Vector2) -> Vector2:
	var dpos := Vector2(float(door.get("x", 0.0)), float(door.get("z", 0.0)))
	var out: Vector2 = door.get("out", Vector2(0, 1))
	var side := Vector2(out.y, -out.x)
	var pitch := span.y + STAGE_AISLE_M
	var col := span.x * 0.5 + STAGE_AISLE_M * 0.5
	return dpos + out * (STAGE_GAP_M + span.y * 0.5 + float(rank / 2) * pitch) + side * (col if rank % 2 == 1 else -col)


## Where a crate that did not fit is set down: beside the door, outside the
## staging columns.
static func overflow_xz(door: Dictionary, k: int, span: Vector2) -> Vector2:
	var dpos := Vector2(float(door.get("x", 0.0)), float(door.get("z", 0.0)))
	var out: Vector2 = door.get("out", Vector2(0, 1))
	var side := Vector2(out.y, -out.x)
	var off := span.x * 1.5 + STAGE_AISLE_M + float(k / 2) * (span.x + 0.4)
	return dpos + out * 1.0 + side * (off if k % 2 == 0 else -off)


## The biggest crate footprint among packed specs: Vector2(across, along).
static func span_of(items: Array) -> Vector2:
	var m := 0.6
	for it in items:
		var d: Dictionary = it
		m = maxf(m, maxf(float(d.get("w_m", 0.0)), float(d.get("d_m", 0.0))))
	return Vector2(m, m)


## The quarter turn of the bay's solver x axis in the host (a side-loaded bay
## runs across the vehicle).
static func _frame_yaw_deg(b: Dictionary) -> float:
	var xa: Vector3 = (b.get("frame", {}) as Dictionary).get("x_axis", Vector3(1, 0, 0))
	return 90.0 if absf(xa.z) > 0.5 else 0.0


## A solver placement -> the crate's stow_local [x, y, z, yaw_rel] in the host.
static func stow_local_for(b: Dictionary, placement: Dictionary, item: Dictionary) -> Array:
	var p3: Vector3 = placement["pos"]
	var s3: Vector3 = placement["size"]
	var local := bay_to_local(b, Vector3(p3.x + s3.x * 0.5, p3.y, p3.z + s3.z * 0.5))
	var turned := absf(s3.x - float(item.get("d_m", s3.x))) < 0.001 \
		and absf(s3.x - float(item.get("w_m", -1.0))) > 0.001
	var yaw_rel := (90.0 if turned else 0.0) + _frame_yaw_deg(b)
	return [local.x, local.y, local.z, yaw_rel]


## THE stowed-crate rule, for records: where a crate stowed in a host stands
## ({x, z, y_offset, yaw}), from the host's pose and the crate's stow_local.
## {} when the crate carries no stow_local.
static func place_stowed(host_rec: Dictionary, crate_rec: Dictionary) -> Dictionary:
	var sl: Variant = crate_rec.get("stow_local")
	if not (sl is Array) or (sl as Array).size() < 4:
		return {}
	var p := local_to_world_xz(host_rec, Vector3(float(sl[0]), float(sl[1]), float(sl[2])))
	return {"x": p.x, "z": p.y, "y_offset": float(sl[1]),
		"yaw": fposmod(float(host_rec.get("yaw", 0.0)) + float(sl[3]), 360.0)}


## The same rule for the crate's NODE while its host moves: the host's ground
## point under its origin and its yaw (radians). The crate's model turns with
## the host; its node stays unrotated (the prop contract).
static func place_stowed_node(node: Node3D, host_ground: Vector3, host_yaw: float, crate_rec: Dictionary) -> void:
	var sl: Variant = crate_rec.get("stow_local")
	if node == null or not (sl is Array) or (sl as Array).size() < 4:
		return
	var b := Basis(Vector3.UP, host_yaw)
	node.global_transform = Transform3D(Basis.IDENTITY,
		host_ground + b * Vector3(float(sl[0]), float(sl[1]), float(sl[2])))
	var m := node.get_node_or_null("ModelRoot") as Node3D
	if m != null:
		m.rotation.y = host_yaw + deg_to_rad(float(sl[3]))


## The crates stowed in a host: [record].
static func stowed_in(layer_props: Array, host_id: String) -> Array:
	var out: Array = []
	for r in layer_props:
		var rec: Dictionary = r
		if str(rec.get("stowed_in", "")) == host_id:
			out.append(rec)
	return out


## Re-seat a host's stowed crates at its record's pose: {crate id: patch}.
static func reseat_patches(layer_props: Array, host_rec: Dictionary) -> Dictionary:
	var out := {}
	for rec in stowed_in(layer_props, str(host_rec.get("id", ""))):
		var pt := place_stowed(host_rec, rec)
		if not pt.is_empty():
			out[str((rec as Dictionary).get("id", ""))] = pt
	return out


## Stow crates into a host's bay alongside what it already carries: the whole
## load is packed again (inside a closed box nobody sees the shuffle) and every
## crate that fits gets its slot. `entries` = [{id, spec (PackedSpec)}], the
## ones already stowed first. Returns {patches: {id: patch}, left: [ids that
## did not fit]}; patches carry stowed_in, stow_local, unload_rank,
## collision_enabled false and the world pose.
static func restow_patches(host_rec: Dictionary, entries: Array) -> Dictionary:
	var out := {"patches": {}, "left": []}
	var b := host_bay(host_rec)
	if b.is_empty():
		for e in entries:
			(out["left"] as Array).append(str((e as Dictionary).get("id", "")))
		return out
	var items: Array = []
	var ids: Array = []
	for e in entries:
		var spec: Dictionary = ((e as Dictionary).get("spec", {}) as Dictionary).duplicate(true)
		if spec.is_empty():
			(out["left"] as Array).append(str((e as Dictionary).get("id", "")))
			continue
		spec["this_side_up"] = true
		items.append(spec)
		ids.append(str((e as Dictionary).get("id", "")))
	if items.is_empty():
		return out
	var solved := PackSolver.solve(b, items)
	var placed := {}
	for pl in solved.get("placements", []):
		placed[int((pl as Dictionary)["item_index"])] = pl
	var ranked: Array = (solved.get("placements", []) as Array).duplicate()
	ranked.sort_custom(func(a: Dictionary, c: Dictionary) -> bool:
		var pa: Vector3 = a["pos"]
		var sa: Vector3 = a["size"]
		var pc: Vector3 = c["pos"]
		var sc: Vector3 = c["size"]
		if absf((pa.y + sa.y) - (pc.y + sc.y)) > 0.001:
			return (pa.y + sa.y) > (pc.y + sc.y)
		if absf((pa.z + sa.z) - (pc.z + sc.z)) > 0.001:
			return (pa.z + sa.z) > (pc.z + sc.z)
		return int(a["item_index"]) < int(c["item_index"]))
	var rank := {}
	for k in ranked.size():
		rank[int((ranked[k] as Dictionary)["item_index"])] = k
	var hid := str(host_rec.get("id", ""))
	for i in ids.size():
		if not placed.has(i):
			(out["left"] as Array).append(ids[i])
			continue
		var sl := stow_local_for(b, placed[i], items[i])
		var pose := place_stowed(host_rec, {"stow_local": sl})
		var patch := {"stowed_in": hid, "stow_local": sl, "unload_rank": int(rank.get(i, i)),
			"collision_enabled": false}
		patch.merge(pose, true)
		(out["patches"] as Dictionary)[ids[i]] = patch
	return out


## THE spawn path: a delivery scenario's units STOWED in a placed host (a
## container or a living vehicle), records added to `layer` (the
## UnpackScenario contract: crates `packed`, `stowed_in` the host with
## `stow_local`, `delivery_id` / `delivery_slot`, an unload rank (LIFO) and a
## staging slot outside the door sized from the crates). Overflow is set down
## beside the door. The host keeps the `delivery` blob. Returns
## {scenario_id, container_prop_id (the host), crate_ids (unload order), door}
## or {}.
static func spawn_into(layer: PlacedPropLayer, scenario_id: String, host_id: String,
		abs_h: float = 0.0) -> Dictionary:
	if layer == null:
		return {}
	var hrec := layer.find_by_id(host_id)
	var sc := UnpackScenario.find(scenario_id)
	if hrec.is_empty() or sc.is_empty():
		return {}
	var b := host_bay(hrec)
	if b.is_empty():
		return {}
	var plan := UnpackScenario.stow_plan(scenario_id, b)
	var door := door_xz(hrec)
	if door.is_empty():
		return {}
	var items: Array = plan.get("items", [])
	var span := span_of(items)
	var hyaw := float(hrec.get("yaw", 0.0))
	var placed_by_item := {}
	for pl in plan.get("placements", []):
		placed_by_item[int((pl as Dictionary)["item_index"])] = pl
	var rank_of := {}
	var order: Array = plan.get("order", [])
	for i in order.size():
		rank_of[int(order[i])] = i
	var by_slot := {}
	var slot := 0
	var spill := 0
	for unit in sc.get("units", []):
		var u: Dictionary = unit
		var model_id := str(u.get("model_id", ""))
		for _i in maxi(int(u.get("count", 1)), 1):
			var rank := int(rank_of.get(slot, -1))
			var patch := {"packed": true, "delivery_id": host_id, "delivery_slot": slot}
			var pos := Vector2(float(door["x"]), float(door["z"]))
			var yaw := hyaw
			if placed_by_item.has(slot) and slot < items.size():
				var sl := stow_local_for(b, placed_by_item[slot], items[slot])
				var pose := place_stowed(hrec, {"stow_local": sl})
				pos = Vector2(float(pose["x"]), float(pose["z"]))
				yaw = float(pose["yaw"])
				patch["y_offset"] = float(pose["y_offset"])
				patch["stowed_in"] = host_id
				patch["stow_local"] = sl
				patch["unload_rank"] = maxi(rank, 0)
				# Inside a closed box: neither walkable-into nor clickable; the
				# crew has to bring it out first.
				patch["collision_enabled"] = false
			else:
				pos = overflow_xz(door, spill, span)
				spill += 1
			var stage := staging_xz(door, rank if rank >= 0 else slot, span)
			patch["staging"] = {"x": stage.x, "z": stage.y}
			var pid := layer.add_free_prop(model_id, pos.x, 0.0, pos.y, yaw)
			if pid.is_empty():
				continue
			if bool(u.get("linkage_default", false)):
				patch["linkage_spec"] = LinkageParams.new().to_config()
			layer.update_prop(pid, patch)
			by_slot[slot] = pid
			slot += 1
	# Emit in UNLOAD order so every consumer inherits LIFO for free.
	var crate_ids: Array = []
	for oi in order:
		if by_slot.has(int(oi)):
			crate_ids.append(by_slot[int(oi)])
	for k in by_slot:
		if not crate_ids.has(by_slot[k]):
			crate_ids.append(by_slot[k])
	layer.update_prop(host_id, {"delivery": {"scenario_id": scenario_id,
		"crate_ids": crate_ids.duplicate(), "delivered_h": abs_h}})
	return {"scenario_id": scenario_id, "container_prop_id": host_id, "crate_ids": crate_ids,
		"door": {"x": float(door["x"]), "z": float(door["z"])}}


## A delivery stowed in a placed vehicle's bay (spawn_into on it).
static func spawn_in_vehicle(layer: PlacedPropLayer, scenario_id: String, vehicle_id: String,
		abs_h: float = 0.0) -> Dictionary:
	if layer == null or not VehicleBuilder.handles(str(layer.find_by_id(vehicle_id).get("model_id", ""))):
		return {}
	return spawn_into(layer, scenario_id, vehicle_id, abs_h)

class_name VehicleCargo
extends RefCounted

## A living vehicle's cargo bay, as the packing code sees a container: the
## largest clear floor rectangle the interior leaves (nothing standing on it),
## the full inside height over it, the biggest door it is loaded through and
## the payload left — a ContainerCatalog-shaped entry, so PackSolver and
## ContainerCatalog.fits_through_door work on it unchanged. Kits are stowed in
## it (`spawn_in_vehicle`, the UnpackScenario contract: crates `packed`,
## `stowed_in` the vehicle, an unload rank and a staging slot outside the door)
## and ride along with it (`stow_local` on each crate, PlacedVehicle re-seats
## them). Pure.
##
## The bay's solver frame (PackSolver: x across, y up, z the load length with
## the DOOR at high z) is laid into the vehicle: through a rear door the length
## runs back (+Z); through a side door only, it runs across to the curb side
## (+X). `frame` = {origin (the nose corner on the floor), x_axis, z_axis},
## vehicle-local.

const CELL_M := 0.1
## Smallest floor worth calling a bay.
const MIN_AREA_M2 := 0.5
## Crates set down this far outside the door, in rows this far apart.
const STAGE_OUT_M := 2.0
const STAGE_PITCH_M := 1.6


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


## The nearest cargo host's door to `pos` within `reach` among placed records:
## a shipping container's (5 m off its door end) or a living vehicle's bay
## door. {x, z} or {}.
static func door_near(records: Array, pos: Vector2, reach: float) -> Dictionary:
	var best_d := reach
	var out := {}
	for r in records:
		var rec: Dictionary = r
		var mid := str(rec.get("model_id", ""))
		var cpos := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
		var dist := pos.distance_to(cpos)
		if dist >= best_d:
			continue
		if mid == "cargo_container":
			var yaw := deg_to_rad(float(rec.get("yaw", 0.0)))
			var door := cpos + Vector2(sin(yaw), cos(yaw)) * 5.0
			best_d = dist
			out = {"x": door.x, "z": door.y}
		elif VehicleBuilder.handles(mid):
			var d := VehicleDesign.solve(VehicleBuilder.spec_for_record(rec))
			var dd := door_outside(d, rec)
			if not dd.is_empty():
				best_d = dist
				out = {"x": float(dd["x"]), "z": float(dd["z"])}
	return out


## Stow a delivery scenario's units in a placed vehicle's bay: crate records
## added to `layer` STOWED in it (PlacedPropService layer contract as in
## UnpackScenario.spawn), each with `stow_local` [x, y, z, yaw_rel] so it rides
## along, and staging slots in rows outside the door. Overflow is set down
## beside the door. Returns {container_prop_id (the vehicle), crate_ids
## (unload order), scenario_id, door} or {}.
static func spawn_in_vehicle(layer: PlacedPropLayer, scenario_id: String, vehicle_id: String,
		abs_h: float = 0.0) -> Dictionary:
	if layer == null:
		return {}
	var vrec := layer.find_by_id(vehicle_id)
	if vrec.is_empty():
		return {}
	var d := VehicleDesign.solve(VehicleBuilder.spec_for_record(vrec))
	var b := bay(d)
	if b.is_empty():
		return {}
	var plan := UnpackScenario.stow_plan(scenario_id, b)
	var sc := UnpackScenario.find(scenario_id)
	if sc.is_empty():
		return {}
	var door := door_outside(d, vrec)
	var dpos := Vector2(float(door["x"]), float(door["z"]))
	var dout: Vector2 = door["out"]
	var side := Vector2(dout.y, -dout.x)
	var vyaw := float(vrec.get("yaw", 0.0))
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
			var patch := {"packed": true, "delivery_id": vehicle_id, "delivery_slot": slot}
			var pos := dpos
			var yaw := vyaw
			if placed_by_item.has(slot):
				var pl2: Dictionary = placed_by_item[slot]
				var p3: Vector3 = pl2["pos"]
				var s3: Vector3 = pl2["size"]
				var local := bay_to_local(b, Vector3(p3.x + s3.x * 0.5, p3.y, p3.z + s3.z * 0.5))
				pos = local_to_world_xz(vrec, local)
				var turned := absf(s3.x - float((plan["items"] as Array)[slot].get("d_m", s3.x))) < 0.001 \
					and absf(s3.x - float((plan["items"] as Array)[slot].get("w_m", -1.0))) > 0.001
				var yaw_rel := 90.0 if turned else 0.0
				if str(b["door_where"]) != "rear":
					yaw_rel += 90.0
				yaw = vyaw + yaw_rel
				patch["y_offset"] = local.y
				patch["stowed_in"] = vehicle_id
				patch["stow_local"] = [local.x, local.y, local.z, yaw_rel]
				patch["unload_rank"] = maxi(rank, 0)
				patch["collision_enabled"] = false
			else:
				pos = dpos + dout * (1.0 + float(spill / 2) * 1.4) + side * (float(spill % 2) * 1.6 - 0.8)
				spill += 1
			var r2 := rank if rank >= 0 else slot
			var stage := dpos + dout * (STAGE_OUT_M + float(r2 / 2) * STAGE_PITCH_M) + side * (float(r2 % 2) * 3.0 - 1.5)
			patch["staging"] = {"x": stage.x, "z": stage.y}
			var pid := layer.add_free_prop(model_id, pos.x, 0.0, pos.y, yaw)
			if pid.is_empty():
				continue
			if bool(u.get("linkage_default", false)):
				patch["linkage_spec"] = LinkageParams.new().to_config()
			layer.update_prop(pid, patch)
			by_slot[slot] = pid
			slot += 1
	var crate_ids: Array = []
	for oi in order:
		if by_slot.has(int(oi)):
			crate_ids.append(by_slot[int(oi)])
	for k in by_slot:
		if not crate_ids.has(by_slot[k]):
			crate_ids.append(by_slot[k])
	layer.update_prop(vehicle_id, {"delivery": {"scenario_id": scenario_id,
		"crate_ids": crate_ids.duplicate(), "delivered_h": abs_h}})
	return {"scenario_id": scenario_id, "container_prop_id": vehicle_id, "crate_ids": crate_ids,
		"door": {"x": dpos.x, "z": dpos.y}}


## Re-seat a vehicle's stowed crates at its record's pose: {crate id: patch}.
static func reseat_patches(layer_props: Array, vrec: Dictionary) -> Dictionary:
	var out := {}
	var vid := str(vrec.get("id", ""))
	for r in layer_props:
		var rec: Dictionary = r
		if str(rec.get("stowed_in", "")) != vid or not (rec.get("stow_local") is Array):
			continue
		var sl: Array = rec["stow_local"]
		if sl.size() < 4:
			continue
		var p := local_to_world_xz(vrec, Vector3(float(sl[0]), float(sl[1]), float(sl[2])))
		out[str(rec.get("id", ""))] = {"x": p.x, "z": p.y,
			"yaw": fposmod(float(vrec.get("yaw", 0.0)) + float(sl[3]), 360.0)}
	return out

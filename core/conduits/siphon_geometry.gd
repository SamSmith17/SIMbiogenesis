class_name SiphonGeometry
extends RefCounted

## Pure measurements off a siphon turbine's GLB, shared by the WORLD runtime
## (`SiphonDipTube`) and the Lab's close-up (`HydroTurbineCloseup`) so the dip
## tube hangs from the same point in both. Everything is expressed in the
## MODEL-ROOT frame and composed from LOCAL transforms (`local_chain`), never
## `global_transform`, because both callers measure from a deferred build
## where the global cache can still be stale.
##
## The machine: a vertical RISER (the crest, the motor on top) and a
## horizontal LEG the runner sits in. The leg runs out past the runner to a
## 6″ 90° PVC ELBOW on the intake side — one side of the elbow on the
## turbine's inlet, the other side open and turned DOWN. The dip tube IS a
## straight 6″ pipe pushed into that open side, so it hangs from the elbow's
## open end and only its length changes (`elbow_outlet`, `dip_anchor_for_
## model_root`). On the shipped GLB the elbow is `Geom3D_22`, a 0.207 ×
## 0.293 × 0.293 m box at the far end of the leg (measured with
## glb_dump_diag, 2026-10-18); the first cut hung the tube off the leg's end
## NEAREST the runner (`intake_fitting`, kept as the fallback for a model
## with no elbow), which on this model is under the riser, 0.7 m from the
## elbow. The connection PORT (`res_in_0`) is where the 3D wire plugs in and
## may sit anywhere on the model, which is why the dip tube must not hang
## off it either.


## Compose LOCAL transforms from `node` up to (but excluding) `stop`.
static func local_chain(node: Node3D, stop: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != stop:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Every MeshInstance3D under `model_root` that is not part of the runner.
static func housing_meshes(model_root: Node3D, runner: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model_root == null:
		return out
	for n: Node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if runner != null and (mi == runner or runner.is_ancestor_of(mi)):
			continue
		out.append(mi)
	return out


## Centre of the runner's mesh AABB in model-root space.
static func runner_centre(model_root: Node3D, runner: Node3D) -> Vector3:
	var mi := first_mesh(runner)
	if mi == null or mi.mesh == null or model_root == null:
		return Vector3.ZERO
	return local_chain(mi, model_root) * mi.mesh.get_aabb().get_center()


static func first_mesh(root: Node) -> MeshInstance3D:
	if root == null:
		return null
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		return n as MeshInstance3D
	return null


## The runner's spin axis in model-root space: the catalog's `spin_axis`, else
## the thinnest extent of the runner's own mesh AABB carried up the chain (a
## propeller / Pelton disc is flat along its shaft).
static func runner_axis_local(model_id: String, model_root: Node3D, runner: Node3D) -> Vector3:
	match ModelCatalog.spin_axis_for(model_id):
		"x": return Vector3.RIGHT
		"y": return Vector3.UP
		"z": return Vector3.BACK
	var mi := first_mesh(runner)
	if mi == null or mi.mesh == null or model_root == null:
		return Vector3.BACK
	var sz := mi.mesh.get_aabb().size
	var thin := Vector3.BACK
	if sz.x <= sz.y and sz.x <= sz.z:
		thin = Vector3.RIGHT
	elif sz.y <= sz.x and sz.y <= sz.z:
		thin = Vector3.UP
	var a := (local_chain(mi, model_root).basis * thin).normalized()
	return a if a.length_squared() > 1e-6 else Vector3.BACK


## The housing's two legs, measured off the meshes: the vertical riser (the
## tallest pipe-like mesh) and the horizontal leg the runner sits in (the
## pipe-like mesh with real extent along the spin axis nearest the runner).
## Returns `{riser: AABB, leg: AABB}` in model-root space; a key is absent
## when the model has no such pipe (a stand-in box).
static func pipe_legs(model_root: Node3D, meshes: Array, axis_local: Vector3,
		runner_c: Vector3) -> Dictionary:
	var out := {}
	if model_root == null:
		return out
	var axis := axis_local.normalized()
	var best_riser := AABB()
	var best_riser_h := 0.0
	var best_leg := AABB()
	var best_leg_d := 0.0
	for m: Variant in meshes:
		var mi := m as MeshInstance3D
		if mi == null or not is_instance_valid(mi) or mi.mesh == null:
			continue
		var box: AABB = local_chain(mi, model_root) * mi.mesh.get_aabb()
		var sz := box.size.abs()
		var vol := sz.x * sz.y * sz.z
		if vol < 1e-5:
			continue
		# Pipe-like: the two cross extents within 0.6 of each other.
		var ex := [sz.x, sz.y, sz.z]
		ex.sort()
		if float(ex[0]) < 0.6 * float(ex[1]):
			continue
		if sz.y >= 1.1 * maxf(sz.x, sz.z) and sz.y > best_riser_h:
			best_riser_h = sz.y
			best_riser = box
		var along := absf(sz.dot(axis))
		var d_run := box.get_center().distance_to(runner_c)
		if absf(axis.y) < 0.5 and along >= 0.5 * float(ex[1]) \
				and (best_leg_d <= 0.0 or d_run < best_leg_d):
			best_leg_d = d_run
			best_leg = box
	if best_riser_h > 0.0:
		out["riser"] = best_riser
	if best_leg.size.length_squared() > 0.0:
		out["leg"] = best_leg
	return out


## The 6″ intake fitting: the open end of the runner's leg nearest the runner.
## Returns `{pos: Vector3, dir: Vector3, radius: float}` in model-root space
## (`dir` = outward along the leg's axis, `radius` = the leg's bore), or empty
## when the model has no measurable leg.
static func intake_fitting(model_root: Node3D, meshes: Array, axis_local: Vector3,
		runner_c: Vector3) -> Dictionary:
	var legs := pipe_legs(model_root, meshes, axis_local, runner_c)
	if not legs.has("leg"):
		return {}
	var axis := axis_local.normalized()
	var lb: AABB = legs["leg"]
	var c := lb.get_center()
	var half := absf(lb.size.dot(axis)) * 0.5
	var a := c + axis * half
	var b := c - axis * half
	# The intake end is the one the runner sits nearer.
	var pos := a if runner_c.distance_to(a) <= runner_c.distance_to(b) else b
	var dir := (pos - c).normalized() if pos.distance_to(c) > 1e-5 else axis
	# The bore is the larger CROSS extent — never the extent along the leg.
	var ex := [lb.size.x, lb.size.y, lb.size.z]
	ex.sort()
	var r := float(ex[1]) * 0.5
	return {"pos": pos, "dir": dir, "radius": r}


## The 90° elbow on the intake side and its OPEN end — where the dip tube
## attaches. An elbow reads as the one mesh whose extents along the leg's axis
## and vertically match (the two legs of a 90° fitting, equal within
## `ELBOW_TOL`), both longer than its cross extent (the pipe's OD), that sits
## ON the leg's line (the runner's height inside its vertical span, within a
## bore of the leg sideways) and farthest from the runner along the axis (the
## riser end has the motor, not an elbow). The open end: the elbow extends
## past the leg's axis further on one side — that is the side it turns to —
## and the straight leg's centreline sits one bore-radius in from the elbow's
## far face. Returns `{pos, dir, radius, box}` in model-root space (`dir` =
## the way the open end faces, DOWN on the shipped model), or empty.
const ELBOW_TOL := 0.15


static func elbow_outlet(model_root: Node3D, meshes: Array, axis_local: Vector3,
		runner_c: Vector3) -> Dictionary:
	if model_root == null:
		return {}
	var axis := axis_local.normalized()
	if absf(axis.y) > 0.5 or axis.length_squared() < 1e-6:
		return {}   # the leg is horizontal on this machine; a vertical shaft has no such elbow
	var side := axis.cross(Vector3.UP).normalized()
	var best := AABB()
	var best_d := -1.0
	for m: Variant in meshes:
		var mi := m as MeshInstance3D
		if mi == null or not is_instance_valid(mi) or mi.mesh == null:
			continue
		var box: AABB = local_chain(mi, model_root) * mi.mesh.get_aabb()
		var sz := box.size.abs()
		var along := absf(sz.dot(axis))
		var vert := sz.y
		var cross := absf(sz.dot(side))
		if cross < 0.02 or along < 1e-4 or vert < 1e-4:
			continue
		if absf(along - vert) > ELBOW_TOL * maxf(along, vert):
			continue
		if minf(along, vert) < 1.1 * cross:
			continue
		var c := box.get_center()
		if runner_c.y < box.position.y - 1e-4 or runner_c.y > box.end.y + 1e-4:
			continue
		if absf((c - runner_c).dot(side)) > cross:
			continue
		var d := absf((c - runner_c).dot(axis))
		if d > best_d:
			best_d = d
			best = box
	if best_d < 0.0:
		return {}
	var sz_b := best.size.abs()
	var cross_b := absf(sz_b.dot(side))
	var r := cross_b * 0.5
	var c_b := best.get_center()
	var away := axis if (c_b - runner_c).dot(axis) >= 0.0 else -axis
	var far_s := c_b.dot(away) + absf(sz_b.dot(away)) * 0.5
	var below := runner_c.y - best.position.y
	var above := best.end.y - runner_c.y
	var down := below >= above
	var pos := c_b - away * c_b.dot(away) + away * (far_s - r)
	pos = pos - Vector3.UP * pos.y + Vector3.UP * (best.position.y if down else best.end.y)
	return {"pos": pos, "dir": Vector3.DOWN if down else Vector3.UP, "radius": r, "box": best}


## Whole-machine convenience for the WORLD runtime: measure the fitting off a
## placed prop's ModelRoot. `runner_name` is the catalog `turbine_node`.
## Returns the fitting in model-root space plus the root, or empty.
static func fitting_for_model_root(model_root: Node3D, model_id: String,
		runner_name: String) -> Dictionary:
	if model_root == null:
		return {}
	var runner: Node3D = null
	if not runner_name.is_empty():
		runner = model_root.find_child(runner_name, true, false) as Node3D
	if runner == null:
		runner = model_root.find_child("Pelton Wheel*", true, false) as Node3D
	var meshes := housing_meshes(model_root, runner)
	var rc := runner_centre(model_root, runner) if runner != null else Vector3.ZERO
	var axis := runner_axis_local(model_id, model_root, runner)
	var fit := intake_fitting(model_root, meshes, axis, rc)
	if fit.is_empty():
		return {}
	fit["runner_centre"] = rc
	fit["axis"] = axis
	return fit


## Where the dip tube hangs from, for the world runtime and the Lab alike: the
## 90° elbow's open end when the model has one (`elbow: true`), else the leg's
## intake fitting. Same keys as `fitting_for_model_root` (`pos`, `dir`,
## `radius`, `runner_centre`, `axis`), model-root space.
static func dip_anchor_for_model_root(model_root: Node3D, model_id: String,
		runner_name: String) -> Dictionary:
	if model_root == null:
		return {}
	var runner: Node3D = null
	if not runner_name.is_empty():
		runner = model_root.find_child(runner_name, true, false) as Node3D
	if runner == null:
		runner = model_root.find_child("Pelton Wheel*", true, false) as Node3D
	var meshes := housing_meshes(model_root, runner)
	var rc := runner_centre(model_root, runner) if runner != null else Vector3.ZERO
	var axis := runner_axis_local(model_id, model_root, runner)
	var elbow := elbow_outlet(model_root, meshes, axis, rc)
	if not elbow.is_empty():
		return {"pos": elbow["pos"], "dir": elbow["dir"], "radius": float(elbow["radius"]),
			"runner_centre": rc, "axis": axis, "elbow": true}
	var fit := intake_fitting(model_root, meshes, axis, rc)
	if fit.is_empty():
		return {}
	fit["runner_centre"] = rc
	fit["axis"] = axis
	fit["elbow"] = false
	return fit

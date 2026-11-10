class_name LightHosts
extends RefCounted

## J lights that move with the placed prop they hang on (a string under a
## dome, a spot on a container wall, a mover on a pallet rack).
##
## A light's HOST is the placed prop whose model bounds hold it. It is worked
## out whenever the light is placed or moved (PlacedLightService.commit) and
## stored on the light record:
##   host_id   — the prop id ("" = on the world, not on a prop)
##   host_xf   — the prop's model frame (PlacedPropRuntime.model_world_xf)
##               when the light was attached, 12 floats
##   host_auto — false once the player detached it by hand: it stays put
##               until they attach it again, wherever it is moved to
## When the prop moves (PlacedPropService / the loader), every light hosted
## on it is carried by the change of frame: position, rotation, a string's
## every pin. Lights saved before hosts existed (no host_id key) are adopted
## the first time their prop moves, by the same bounds test against the
## prop's pose before the move.
##
## The frame is the ModelRoot's rotation + scale at the prop's position —
## computed from the RECORD, so a prop node being previewed at a new pose
## (the prop editor's gumball) never confuses the old frame.

const MARGIN_M := 0.35
const META_AABB := "light_host_aabb"
const POSE_KEYS := ["x", "z", "yaw", "pitch", "roll", "y_offset", "scale", "ground_y", "y"]


static func patch_moves(patch: Dictionary) -> bool:
	for k in POSE_KEYS:
		if patch.has(k):
			return true
	return false


static func xf_to_array(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z,
		t.origin.x, t.origin.y, t.origin.z]


static func array_to_xf(a: Variant) -> Transform3D:
	if not (a is Array) or (a as Array).size() < 12:
		return Transform3D.IDENTITY
	var v := a as Array
	return Transform3D(Basis(Vector3(float(v[0]), float(v[1]), float(v[2])),
		Vector3(float(v[3]), float(v[4]), float(v[5])), Vector3(float(v[6]), float(v[7]), float(v[8]))),
		Vector3(float(v[9]), float(v[10]), float(v[11])))


## The points a light occupies: its position, or a string's pins.
static func points_of(rec: Dictionary) -> Array:
	if str(rec.get("kind", "")) == "string":
		var pts := PlacedLightLayer.waypoints_of(rec)
		if not pts.is_empty():
			return pts
	return [Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)), float(rec.get("z", 0.0)))]


# -- Prop bounds ---------------------------------------------------------------

## The frame the bounds are measured in: the model's rotation + scale at the
## prop's position (the node twin of PlacedPropRuntime.model_world_xf).
static func node_frame(prop: Node3D) -> Transform3D:
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null or not prop.is_inside_tree():
		return Transform3D(Basis.IDENTITY, prop.global_position)
	return Transform3D(model.global_transform.basis, prop.global_position)


## The prop's model bounds in its frame (cached on the node; a rebuilt prop is
## a new node and measures again).
static func local_bounds(prop: Node3D) -> AABB:
	if prop.has_meta(META_AABB):
		return prop.get_meta(META_AABB)
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	var out := AABB()
	var found := false
	if model != null and prop.is_inside_tree():
		var inv := node_frame(prop).affine_inverse()
		for n in model.find_children("*", "GeometryInstance3D", true, false):
			if n is GPUParticles3D or n is CPUParticles3D or n is Label3D:
				continue
			var gi := n as GeometryInstance3D
			var bb := gi.get_aabb()
			if bb.size.length_squared() < 1e-8:
				continue
			var local: AABB = (inv * gi.global_transform) * bb
			out = local if not found else out.merge(local)
			found = true
	if found:
		prop.set_meta(META_AABB, out)
	return out


## The prop whose bounds (in `frame_of`'s frame — default: where the node
## stands) hold the most of `points`; the smallest box wins a tie. "" = none.
static func find_host(main: Node, points: Array, frame_of: Dictionary = {}) -> String:
	var root := _props_root(main)
	if root == null or points.is_empty():
		return ""
	var best := ""
	var best_n := 0
	var best_vol := INF
	for child in root.get_children():
		if not (child is PlacedProp) or not (child as Node3D).visible:
			continue
		var pid := str((child as PlacedProp).prop_id)
		var bb := local_bounds(child as Node3D)
		if bb.size.length_squared() < 1e-6:
			continue
		var grown := bb.grow(MARGIN_M)
		var frame: Transform3D = frame_of.get(pid, node_frame(child as Node3D))
		var inv := frame.affine_inverse()
		var n := 0
		for p in points:
			if grown.has_point(inv * (p as Vector3)):
				n += 1
		if n == 0:
			continue
		var vol := bb.get_volume()
		if n > best_n or (n == best_n and vol < best_vol):
			best = pid
			best_n = n
			best_vol = vol
	return best


static func _props_root(main: Node) -> Node:
	if main == null:
		return null
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = main
	return terrain.get_node_or_null("PlacedProps")


static func _prop_record(main: Node, prop_id: String) -> Dictionary:
	return PlacedPropService.get_prop_record(main, prop_id) if not prop_id.is_empty() else {}


# -- Attaching -----------------------------------------------------------------

## Attach `rec` to the prop it stands in now (or to nothing). Returns true when
## the record changed. A light the player detached stays detached.
static func resolve(main: Node, rec: Dictionary) -> bool:
	if not bool(rec.get("host_auto", true)):
		return false
	var pid := find_host(main, points_of(rec))
	return _set_host(main, rec, pid)


static func _set_host(main: Node, rec: Dictionary, pid: String) -> bool:
	if pid.is_empty():
		var had := not str(rec.get("host_id", "")).is_empty() or not rec.has("host_id")
		rec["host_id"] = ""
		rec.erase("host_xf")
		return had
	var prec := _prop_record(main, pid)
	if prec.is_empty():
		return false
	var xf := PlacedPropRuntime.model_world_xf(prec, TerrainSurfaceQuery.ground_y_callable(main))
	rec["host_id"] = pid
	rec["host_xf"] = xf_to_array(xf)
	return true


## The player's own choice: attach to the prop it stands in (`on`), or detach
## and keep it where it is whatever moves.
static func set_attached(main: Node, rec: Dictionary, on: bool) -> String:
	if on:
		rec["host_auto"] = true
		resolve(main, rec)
		return str(rec.get("host_id", ""))
	rec["host_auto"] = false
	rec["host_id"] = ""
	rec.erase("host_xf")
	return ""


static func host_label(main: Node, rec: Dictionary) -> String:
	var pid := str(rec.get("host_id", ""))
	if pid.is_empty():
		return ""
	var prec := _prop_record(main, pid)
	if prec.is_empty():
		return ""
	var nm := str(prec.get("name", ""))
	if nm.is_empty():
		nm = str(ModelCatalog.find(str(prec.get("model_id", ""))).get("label", ""))
	return nm if not nm.is_empty() else UiText.from_id(str(prec.get("model_id", "prop")))


# -- Following -----------------------------------------------------------------

## `prop_id` moved from `old_rec`'s pose to `new_rec`'s: carry the lights on
## it. With `commit_records` false only the light NODES move (a live preview);
## the records stay where they are. Returns the ids moved.
static func follow(main: Node, layer: PlacedLightLayer, prop_id: String, old_rec: Dictionary,
		new_rec: Dictionary, commit_records: bool = true) -> Array:
	if layer == null or prop_id.is_empty() or old_rec.is_empty() or new_rec.is_empty():
		return []
	# Packing swaps the model for a crate (another frame): lights stay put.
	if bool(old_rec.get("packed", false)) != bool(new_rec.get("packed", false)):
		return []
	var gy := TerrainSurfaceQuery.ground_y_callable(main)
	var old_xf := PlacedPropRuntime.model_world_xf(old_rec, gy)
	var new_xf := PlacedPropRuntime.model_world_xf(new_rec, gy)
	var moved: Array = []
	for rec in layer.lights:
		var r := rec as Dictionary
		var hosted := str(r.get("host_id", "")) == prop_id
		if not hosted and not r.has("host_id") and bool(r.get("host_auto", true)):
			# A light saved before hosts existed: is it in this prop, at the
			# prop's pose before the move?
			if find_host(main, points_of(r), {prop_id: old_xf}) == prop_id:
				r["host_id"] = prop_id
				r["host_xf"] = xf_to_array(old_xf)
				hosted = true
		if not hosted:
			continue
		var from := array_to_xf(r.get("host_xf", null)) if r.has("host_xf") else old_xf
		var delta := new_xf * from.affine_inverse()
		if delta.is_equal_approx(Transform3D.IDENTITY):
			continue
		var moved_rec := carried(r, delta)
		if commit_records:
			for k in moved_rec:
				r[k] = moved_rec[k]
			r["host_xf"] = xf_to_array(new_xf)
			PlacedLightService.refresh_light(main, str(r.get("id", "")))
		else:
			var node := PlacedLightRuntime.find_node(main, str(r.get("id", "")))
			if node != null:
				var preview: Dictionary = r.duplicate(true)
				for k in moved_rec:
					preview[k] = moved_rec[k]
				PlacedLightRuntime.apply(main, layer, node, preview)
		moved.append(str(r.get("id", "")))
	return moved


## The fields of `rec` after moving it by `delta` (a rigid move; a scaled prop
## scales the offsets with it).
static func carried(rec: Dictionary, delta: Transform3D) -> Dictionary:
	var out: Dictionary = {}
	var p := delta * Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)), float(rec.get("z", 0.0)))
	out["x"] = snappedf(p.x, 0.001)
	out["y"] = snappedf(p.y, 0.001)
	out["z"] = snappedf(p.z, 0.001)
	var rb := LightGizmoMath.basis_of(Vector3(float(rec.get("pitch", 0.0)), float(rec.get("yaw", 0.0)),
		float(rec.get("roll", 0.0))))
	var e := (delta.basis.orthonormalized() * rb).get_euler()
	out["pitch"] = snappedf(rad_to_deg(e.x), 0.01)
	out["yaw"] = snappedf(rad_to_deg(e.y), 0.01)
	out["roll"] = snappedf(rad_to_deg(e.z), 0.01)
	if str(rec.get("kind", "")) == "string":
		var wps: Array = []
		for w in rec.get("waypoints", []):
			var v := delta * PlacedLightLayer.waypoint_vec(w as Dictionary)
			wps.append({"x": snappedf(v.x, 0.001), "y": snappedf(v.y, 0.001), "z": snappedf(v.z, 0.001)})
		out["waypoints"] = wps
		if not wps.is_empty():
			out["x"] = wps[0]["x"]
			out["y"] = wps[0]["y"]
			out["z"] = wps[0]["z"]
	return out


## A prop was deleted: its lights stay where they are, on the world.
static func release(layer: PlacedLightLayer, prop_id: String) -> void:
	if layer == null:
		return
	for rec in layer.lights:
		if str((rec as Dictionary).get("host_id", "")) == prop_id:
			rec["host_id"] = ""
			(rec as Dictionary).erase("host_xf")

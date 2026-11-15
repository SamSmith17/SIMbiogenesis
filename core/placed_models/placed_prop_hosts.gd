class_name PlacedPropHosts
extends RefCounted

## Placed props that stand ON another placed prop and move with it: a solar
## array on a shed roof (PvLab), the beds, FarmBot beds and grow-light racks
## inside a greenhouse.
##
## A hosted CHILD carries on its record
##   mount_host = {kind: "prop", id: <host prop id>, local: [12 floats], owned: bool}
## `local` is the child's frame in the host's frame, both frames from the
## RECORD (`record_frame`, the same frame PvSurfaceAim.record_xf gives), so
## a host moved or turned by any path puts the child back at host × local.
##
## `owned` children are PART of the host (a greenhouse's beds): they are
## packed and unpacked with it, deleted with it and copied when it is
## duplicated. A child that is not owned (a solar array on a roof) is set
## down on the ground when its host is deleted (`release`).
##
## Every move path calls `follow` (records + nodes) or `preview` (nodes
## only, the gumball's live drag): PlacedPropService.update_prop_record /
## move_prop_at, TerrainLoader.update_prop_record / save_prop_from_node /
## preview_prop.

const KEY := "mount_host"
const MAX_DEPTH := 3
const NODES_REBUILD := "rebuild"
const NODES_NONE := "none"
## Record keys that move a prop's frame (any of these in a patch = follow).
const POSE_KEYS := ["x", "z", "yaw", "pitch", "roll", "y_offset", "scale", "ground_y", "y"]


# --- pure maths ----------------------------------------------------------------

static func xf_to_array(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y, t.basis.y.z,
		t.basis.z.x, t.basis.z.y, t.basis.z.z, t.origin.x, t.origin.y, t.origin.z]


static func xf_from_array(a: Variant) -> Transform3D:
	if not (a is Array) or (a as Array).size() < 12:
		return Transform3D.IDENTITY
	var v := a as Array
	return Transform3D(Basis(Vector3(float(v[0]), float(v[1]), float(v[2])),
		Vector3(float(v[3]), float(v[4]), float(v[5])), Vector3(float(v[6]), float(v[7]), float(v[8]))),
		Vector3(float(v[9]), float(v[10]), float(v[11])))


## A record's frame given the ground under it and its foot offset
## (`foot_local_y × world scale`). Same formula as PvSurfaceAim.record_xf.
static func frame(rec: Dictionary, ground_y: float, foot_ws: float) -> Transform3D:
	var y := ground_y - foot_ws + float(rec.get("y_offset", 0.0))
	var b := Basis.from_euler(Vector3(deg_to_rad(float(rec.get("pitch", 0.0))),
		deg_to_rad(float(rec.get("yaw", 0.0))), deg_to_rad(float(rec.get("roll", 0.0)))))
	return Transform3D(b, Vector3(float(rec.get("x", 0.0)), y, float(rec.get("z", 0.0))))


## The record fields that put a prop at frame `xf` — the exact inverse of
## `frame` for the same ground and foot offset.
static func patch_from(xf: Transform3D, ground_y: float, foot_ws: float) -> Dictionary:
	var e := xf.basis.orthonormalized().get_euler()
	return {"x": xf.origin.x, "z": xf.origin.z, "y_offset": xf.origin.y - ground_y + foot_ws,
		"pitch": rad_to_deg(e.x), "yaw": rad_to_deg(e.y), "roll": rad_to_deg(e.z)}


## The child's frame in the host's frame, as stored on `mount_host.local`.
static func local_of(host_xf: Transform3D, child_xf: Transform3D) -> Array:
	return xf_to_array(host_xf.affine_inverse() * child_xf)


## Where a child stands once its host stands at `host_xf`.
static func carried(host_xf: Transform3D, local: Variant) -> Transform3D:
	return host_xf * xf_from_array(local)


## The record's prop link ({} when it stands on no prop).
static func link_of(rec: Dictionary) -> Dictionary:
	var mh: Variant = rec.get(KEY)
	if mh is Dictionary and str((mh as Dictionary).get("kind", "")) == "prop" \
			and not str((mh as Dictionary).get("id", "")).is_empty():
		return mh as Dictionary
	return {}


static func host_of(rec: Dictionary) -> String:
	return str(link_of(rec).get("id", ""))


static func is_owned(rec: Dictionary) -> bool:
	return bool(link_of(rec).get("owned", false))


static func patch_moves(patch: Dictionary) -> bool:
	for k in POSE_KEYS:
		if patch.has(k):
			return true
	return false


# --- the children index ----------------------------------------------------------
## host id -> [child id]. Rebuilt when the layer's prop list is replaced or
## changes size, or after `invalidate` (any write of `mount_host`). Every hit
## is checked against the child's live record, so a stale entry can only cost
## a lookup, never move the wrong prop.

static var _idx: Dictionary = {}
static var _idx_props: Array = []
static var _idx_n := -1
static var _idx_gen := -1
static var _gen := 0


static func invalidate() -> void:
	_gen += 1


static func _ensure_index(layer: PlacedPropLayer) -> void:
	if is_same(_idx_props, layer.props) and _idx_n == layer.props.size() and _idx_gen == _gen:
		return
	_idx = {}
	for rec in layer.props:
		if not (rec is Dictionary):
			continue
		var h := host_of(rec as Dictionary)
		if h.is_empty():
			continue
		if not _idx.has(h):
			_idx[h] = []
		(_idx[h] as Array).append(str((rec as Dictionary).get("id", "")))
	_idx_props = layer.props
	_idx_n = layer.props.size()
	_idx_gen = _gen


## The live records of the props standing on `host_id` (in layer order).
static func children_of(layer: PlacedPropLayer, host_id: String) -> Array:
	var out: Array = []
	if layer == null or host_id.is_empty():
		return out
	_ensure_index(layer)
	for cid in (_idx.get(host_id, []) as Array):
		var rec := layer.find_by_id(str(cid))
		if not rec.is_empty() and host_of(rec) == host_id and str(cid) != host_id:
			out.append(rec)
	return out


## Ids of the children `owned` by the host (part of it).
static func owned_children(layer: PlacedPropLayer, host_id: String) -> Array:
	var out: Array = []
	for rec in children_of(layer, host_id):
		if is_owned(rec):
			out.append(str((rec as Dictionary).get("id", "")))
	return out


## True when `host_id` stands (directly or further up) on `prop_id`: linking
## `prop_id` to `host_id` would make a loop.
static func would_loop(layer: PlacedPropLayer, prop_id: String, host_id: String) -> bool:
	var cur := host_id
	for _i in range(16):
		if cur.is_empty():
			return false
		if cur == prop_id:
			return true
		cur = host_of(layer.find_by_id(cur))
	return true


# --- live frames -------------------------------------------------------------------

static func foot_ws(rec: Dictionary) -> float:
	var mid := str(rec.get("model_id", ""))
	if mid.is_empty():
		return 0.0
	return ModelCatalog.foot_local_y(mid) * ModelCatalog.resolved_scale(mid, float(rec.get("scale", 1.0)))


## A record's frame on the live terrain (== PvSurfaceAim.record_xf).
static func record_frame(main: Node, rec: Dictionary) -> Transform3D:
	var gy := TerrainSurfaceQuery.ground_height_at(main, float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
	return frame(rec, gy, foot_ws(rec))


## The fields that put this child at `xf` on the live terrain.
static func child_patch(main: Node, child_rec: Dictionary, xf: Transform3D) -> Dictionary:
	var gy := TerrainSurfaceQuery.ground_height_at(main, xf.origin.x, xf.origin.z)
	return patch_from(xf, gy, foot_ws(child_rec))


# --- the world ----------------------------------------------------------------------

## Mount `child_id` on `host_id` where it stands now. `owned` = the child is
## part of the host (packs, deletes and copies with it). Returns false on a
## missing record or a loop.
static func attach(main: Node, child_id: String, host_id: String, owned: bool = false) -> bool:
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null or child_id.is_empty() or host_id.is_empty() or child_id == host_id:
		return false
	var crec := layer.find_by_id(child_id)
	var hrec := layer.find_by_id(host_id)
	if crec.is_empty() or hrec.is_empty() or would_loop(layer, child_id, host_id):
		return false
	var link := {"kind": "prop", "id": host_id,
		"local": local_of(record_frame(main, hrec), record_frame(main, crec)), "owned": owned}
	if not layer.update_prop(child_id, {KEY: link}):
		return false
	invalidate()
	PlacedPropService._save_layer(main, layer)
	PlacedPropService._notify_mp_props_edited()
	return true


## Unmount: the child stays where it is and stops following.
static func detach(main: Node, child_id: String) -> bool:
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null or not layer.update_prop(child_id, {KEY: null}):
		return false
	invalidate()
	PlacedPropService._save_layer(main, layer)
	PlacedPropService._notify_mp_props_edited()
	return true


## The host's record moved: every child goes to host × local (records,
## lights, graph sites, nested children). `nodes` NODES_REBUILD respawns each
## child node; NODES_NONE leaves the nodes to a caller that rebuilds every
## prop anyway. Does not save the layer: the caller's save covers the
## children. Returns how many children moved.
static func follow(main: Node, host_id: String, depth: int = 0, nodes: String = NODES_REBUILD) -> int:
	if main == null or depth > MAX_DEPTH:
		return 0
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null:
		return 0
	var hrec := layer.find_by_id(host_id)
	if hrec.is_empty():
		return 0
	var kids := children_of(layer, host_id)
	if kids.is_empty():
		return 0
	var host_xf := record_frame(main, hrec)
	var n := 0
	for rec in kids:
		var link := link_of(rec as Dictionary)
		if not (link.get("local") is Array):
			continue
		var cid := str((rec as Dictionary).get("id", ""))
		var pr := child_patch(main, rec as Dictionary, carried(host_xf, link["local"]))
		if PlacedPropService._update_prop_record_depth(main, cid, pr, depth + 1,
				nodes == NODES_REBUILD, false):
			n += 1
	return n


## The gumball's live drag: the host NODE shows at `host_xf`; its children's
## nodes (and their lights) are shown at host × local. Records do not move —
## the commit's `follow` does that.
static func preview(main: Node, host_id: String, host_xf: Transform3D, depth: int = 0) -> void:
	if main == null or depth > MAX_DEPTH:
		return
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null:
		return
	var gy_fn := TerrainSurfaceQuery.ground_y_callable(main)
	for rec in children_of(layer, host_id):
		var link := link_of(rec as Dictionary)
		if not (link.get("local") is Array):
			continue
		var cid := str((rec as Dictionary).get("id", ""))
		var cxf := carried(host_xf, link["local"])
		var shown := (rec as Dictionary).duplicate(true)
		shown.merge(child_patch(main, rec as Dictionary, cxf), true)
		var node := PlacedPropRuntime.find_by_prop_id(main, cid)
		if node != null and is_instance_valid(node):
			PlacedPropRuntime.apply_record_to_prop(node, shown, gy_fn)
		PlacedLightService.follow_prop(main, cid, rec as Dictionary, shown, false)
		preview(main, cid, cxf, depth + 1)


## A host is deleted: children that are not part of it come down to the
## ground under them and stop following. Owned children are the caller's
## (TerrainLoader.delete_prop_by_id deletes them first).
static func release(main: Node, host_id: String) -> int:
	var layer := PlacedPropService._layer_for_main(main)
	if layer == null:
		return 0
	var n := 0
	for rec in children_of(layer, host_id):
		if is_owned(rec as Dictionary):
			continue
		PlacedPropService.update_prop_record(main, str((rec as Dictionary).get("id", "")),
			{"y_offset": 0.0, "pitch": 0.0, "roll": 0.0, KEY: null}, true)
		n += 1
	invalidate()
	return n

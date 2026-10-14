class_name PlacedLightService
extends RefCounted

## The J Light Studio's model service: which lights file this map uses, the
## selection, undo/redo, and every mutation (each refreshes only the nodes it
## touched). Static, like the rest of the placed-* services, so the in-world
## nodes, the dock and interaction_focus share one state without wiring.
##
## Mutation discipline: the dock calls checkpoint() BEFORE a gesture (a drag,
## a slider grab, a delete) and commit() after it; the helpers in between only
## change data + nodes. One gesture = one undo step, and the file is written
## once per gesture, not per mouse-motion event.

const UNDO_DEPTH := 30
const DOCK_SCRIPT := "res://scenes/ui/lights/light_dock.gd"
const DOCK_NAME := "LightStudioDock"

static var _layer: PlacedLightLayer = null
static var _key := ""
static var _path := ""
static var _built_for := ""
static var _studio_open := false
static var selection: Array[String] = []
## kind -> style id new lights of that kind get.
static var active_style: Dictionary = {}
static var _undo: Array = []
static var _redo: Array = []
static var _listeners: Array[Callable] = []


# -- File / layer ------------------------------------------------------------

## "<lat>_<lon>" on a generated map (one lights file per SITE), else
## "scene_<basename>" — which is exactly the v2 path, so a built-in map simply
## reads its old file and migrates it.
static func map_key(main: Node) -> String:
	if main == null:
		return ""
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and "_lat" in loader:
		var lat := float(loader.get("_lat"))
		var lon := float(loader.get("_lon"))
		if absf(lat) > 1e-9 or absf(lon) > 1e-9:
			return "%s_%s" % [CoordToken.token(lat), CoordToken.token(lon)]
	var tag := str(main.scene_file_path).get_file().get_basename()
	return "scene_%s" % (tag if not tag.is_empty() else "unknown_scene")


static func get_layer(main: Node) -> PlacedLightLayer:
	if main == null:
		return null
	var key := map_key(main)
	# Compare the RESOLVED path, not the site key: two worlds on one site share
	# the key, and this layer is a static that outlives the scene.
	var path := PlacedLightLayer.path_for_key(key)
	if _layer != null and key == _key and path == _path:
		return _layer
	_layer = PlacedLightLayer.create_empty()
	_key = key
	_path = path
	_built_for = ""
	selection.clear()
	active_style.clear()
	_undo.clear()
	_redo.clear()
	# A dir-storage world starts empty — never adopt the old shared v2 file.
	if not _layer.load_from(_path) and not key.begins_with("scene_") \
			and not WorldPaths.is_dir_world():
		_adopt_shared_legacy_file(main)
	if _layer.migrated_from > 0:
		print("PlacedLightService: migrated lights v%d -> v%d (%s)" % [
			_layer.migrated_from, PlacedLightLayer.VERSION, _path])
		_layer.save_to(_path)
	return _layer


## Every generated map used to share ONE file (keyed by the shell scene's
## basename). The first site to load since v3 adopts it and the shared file is
## renamed, so its lights do not appear on every other site too.
static func _adopt_shared_legacy_file(main: Node) -> void:
	var legacy := PlacedLightLayer.legacy_path_for_scene(str(main.scene_file_path))
	if not FileAccess.file_exists(legacy) or not _layer.load_from(legacy):
		return
	_layer.save_to(_path)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(legacy),
		ProjectSettings.globalize_path(legacy + ".adopted"))
	print("PlacedLightService: adopted the shared legacy lights file into %s" % _path)


static func save(main: Node) -> void:
	if get_layer(main) != null and not _path.is_empty():
		_layer.save_to(_path)


## Build this map's lights once (main.gd on ready, TerrainLoader after load —
## whichever knows the map first; a key change rebuilds).
static func ensure_built(main: Node) -> void:
	var layer := get_layer(main)
	if layer == null or _built_for == _key:
		return
	_built_for = _key
	PlacedLightRuntime.rebuild(main, layer)
	_apply_selection_visuals(main)


static func rebuild_all(main: Node) -> void:
	_built_for = ""
	ensure_built(main)


static func refresh_light(main: Node, id: String) -> void:
	var layer := get_layer(main)
	var rec := layer.find_light(id) if layer != null else {}
	if rec.is_empty():
		PlacedLightRuntime.remove_node(main, id)
		return
	var node := PlacedLightRuntime.find_node(main, id)
	if node == null:
		PlacedLightRuntime.build_one(main, layer, rec)
	else:
		PlacedLightRuntime.apply(main, layer, node, rec)
	_apply_selection_visuals(main)


static func refresh_ids(main: Node, ids: Array) -> void:
	for id in ids:
		refresh_light(main, str(id))


## Every light using one style (a style edit restyles all of them).
static func refresh_style_users(main: Node, sid: String) -> void:
	refresh_ids(main, get_layer(main).lights_with_style(sid))


# -- Studio / listeners ------------------------------------------------------

## The IK spheres show only while the Studio is open or the selection modifier
## is held (ModifierKeys — the event-reported state; Godot's key table sticks
## after Alt+Tab and left every sphere showing).
static func gizmos_visible() -> bool:
	return _studio_open or ModifierKeys.selecting()


## Kept for interaction_focus: while the Studio is up, crosshair focus is
## lights-only.
static func is_placement_active() -> bool:
	return _studio_open


static func is_studio_open() -> bool:
	return _studio_open


static func set_studio_open(on: bool) -> void:
	_studio_open = on


static func add_listener(cb: Callable) -> void:
	if not cb in _listeners:
		_listeners.append(cb)


static func remove_listener(cb: Callable) -> void:
	_listeners.erase(cb)


static func notify() -> void:
	for cb in _listeners.duplicate():
		if cb.is_valid():
			cb.call()
		else:
			_listeners.erase(cb)


static func find_dock(main: Node) -> Control:
	if main == null:
		return null
	var ui := main.get_node_or_null("UILayer")
	var host: Node = ui if ui != null else main
	return host.get_node_or_null(DOCK_NAME) as Control


static func ensure_dock(main: Node) -> Control:
	var dock := find_dock(main)
	if dock != null:
		return dock
	var ui := main.get_node_or_null("UILayer")
	var host: Node = ui if ui != null else main
	var script: GDScript = load(DOCK_SCRIPT)
	dock = Control.new()
	dock.set_script(script)
	dock.name = DOCK_NAME
	host.add_child(dock)
	dock.call("bind_main", main)
	return dock


static func toggle_studio(main: Node) -> void:
	var dock := ensure_dock(main)
	if dock == null:
		return
	if _studio_open:
		dock.call("close")
	else:
		dock.call("open")


static func open_studio_on(main: Node, ids: Array) -> void:
	var dock := ensure_dock(main)
	if dock == null:
		return
	if not _studio_open:
		dock.call("open")
	set_selection(main, ids)


# -- Selection ---------------------------------------------------------------

static func set_selection(main: Node, ids: Array) -> void:
	selection.clear()
	var layer := get_layer(main)
	for id in ids:
		var s := str(id)
		if layer != null and not layer.find_light(s).is_empty() and not s in selection:
			selection.append(s)
	_apply_selection_visuals(main)
	notify()


static func toggle_in_selection(main: Node, id: String) -> void:
	var ids: Array = selection.duplicate()
	if id in ids:
		ids.erase(id)
	else:
		ids.append(id)
	set_selection(main, ids)


static func _apply_selection_visuals(main: Node) -> void:
	var root := main.get_node_or_null(PlacedLightRuntime.ROOT_NAME) if main != null else null
	if root == null:
		return
	for n in root.get_children():
		var id := str(n.get("light_id"))
		if n.has_method("set_selected"):
			n.call("set_selected", id in selection)


static func selection_centroid(main: Node) -> Vector3:
	var layer := get_layer(main)
	if layer == null or selection.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for id in selection:
		c += layer.position_of(layer.find_light(id))
	return c / float(selection.size())


# -- Undo --------------------------------------------------------------------

static func checkpoint(main: Node) -> void:
	var layer := get_layer(main)
	if layer == null:
		return
	_undo.append(layer.serialize())
	if _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()


static func commit(main: Node) -> void:
	save(main)
	notify()


static func can_undo() -> bool:
	return not _undo.is_empty()


static func can_redo() -> bool:
	return not _redo.is_empty()


static func undo(main: Node) -> bool:
	return _swap(main, _undo, _redo)


static func redo(main: Node) -> bool:
	return _swap(main, _redo, _undo)


static func _swap(main: Node, from: Array, to: Array) -> bool:
	var layer := get_layer(main)
	if layer == null or from.is_empty():
		return false
	to.append(layer.serialize())
	layer.deserialize(from.pop_back())
	var keep: Array = []
	for id in selection:
		if not layer.find_light(id).is_empty():
			keep.append(id)
	selection.assign(keep)
	rebuild_all(main)
	commit(main)
	return true


# -- Creation ----------------------------------------------------------------

static func style_for_new(main: Node, kind: String) -> String:
	var layer := get_layer(main)
	var sid := str(active_style.get(kind, ""))
	if sid.is_empty() or not layer.styles.has(sid):
		sid = layer.ensure_default_style(kind)
		active_style[kind] = sid
	return sid


## The style a PRESET places with: one per preset per map (found by its
## `preset_id`), made from the preset's fields the first time. New lights of
## that kind then use it, so everything placed from "Moving-head beam" can be
## restyled together.
static func style_for_preset(main: Node, kind: String, preset_id: String) -> String:
	var layer := get_layer(main)
	if layer == null:
		return ""
	if preset_id.is_empty():
		var d := layer.ensure_default_style(kind)
		active_style[kind] = d
		return d
	for sid in layer.styles.keys():
		var st: Dictionary = layer.styles[sid]
		if str(st.get("kind", "")) == kind and str(st.get("preset_id", "")) == preset_id:
			active_style[kind] = str(sid)
			return str(sid)
	var nsid := layer.add_style(PlacedLightStyles.preset_label(kind, preset_id), kind,
		PlacedLightStyles.preset_fields(preset_id, kind))
	layer.styles[nsid]["preset_id"] = preset_id
	active_style[kind] = nsid
	return nsid


## Spread `phase_deg` evenly over a set of fixtures in the order they stand
## along their longest axis — a row of moving heads becomes a fan / a wave.
static func fan_phases(main: Node, ids: Array) -> void:
	var layer := get_layer(main)
	var recs: Array = []
	for id in ids:
		var r := layer.find_light(str(id))
		if not r.is_empty():
			recs.append(r)
	if recs.size() < 2:
		return
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for r in recs:
		var p := layer.position_of(r)
		lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
		hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	var axis := hi - lo
	var key := 0 if axis.x >= axis.y and axis.x >= axis.z else (1 if axis.y >= axis.z else 2)
	recs.sort_custom(func(a, b) -> bool:
		return layer.position_of(a)[key] < layer.position_of(b)[key])
	for i in recs.size():
		layer.set_field(str(recs[i]["id"]), "phase_deg", 360.0 * float(i) / float(recs.size()), false)
	refresh_ids(main, ids)


static func add_point_light(main: Node, kind: String, pos: Vector3, rot: Vector3) -> String:
	var layer := get_layer(main)
	if layer == null:
		return ""
	var id := layer.add_light(kind, pos, rot, style_for_new(main, kind))
	if not id.is_empty():
		refresh_light(main, id)
	return id


static func add_string(main: Node, points: Array) -> String:
	var layer := get_layer(main)
	if layer == null:
		return ""
	var id := layer.add_string(points, style_for_new(main, "string"))
	if not id.is_empty():
		refresh_light(main, id)
	return id


static func delete_ids(main: Node, ids: Array) -> void:
	var layer := get_layer(main)
	for id in ids:
		var rec := layer.find_light(str(id))
		if not str(rec.get("graph_item_id", "")).is_empty():
			_graph_call(main, "remove_placed_light_load", [str(id)])
		layer.remove_light(str(id))
		PlacedLightRuntime.remove_node(main, str(id))
		selection.erase(str(id))


## Copies share the source's STYLE (a style edit restyles them all) and its
## GROUPS — and a source in no group gets one with its copies, so by default
## everything stamped from one light selects and switches as one set.
static func duplicate_ids(main: Node, ids: Array, delta: Vector3) -> Array:
	var layer := get_layer(main)
	var out: Array = []
	for id in ids:
		var src := layer.find_light(str(id))
		if src.is_empty():
			continue
		if (src.get("group_ids", []) as Array).is_empty():
			layer.add_group("%s set" % layer.style_display_name(str(src.get("style_id", ""))), [str(id)])
		var nid := layer.duplicate_light(str(id), delta)
		if not nid.is_empty():
			out.append(nid)
			refresh_light(main, nid)
	return out


# -- Whole-light drags (first person: GrabController's marker hooks; the dock
#    uses the same three calls) ---------------------------------------------

## {ids, applied} of the drag in progress.
static var _drag: Dictionary = {}


## Start a drag of `id` (a light, or a WHOLE string). `duplicate`: copy it
## first and drag the copy. Returns the id being dragged.
static func begin_drag(main: Node, id: String, duplicate: bool) -> String:
	var got := begin_drag_many(main, [id], duplicate)
	return str(got[0]) if not got.is_empty() else ""


## The same for a whole selection (Ctrl+drag one of them moves them all).
static func begin_drag_many(main: Node, ids: Array, duplicate: bool) -> Array:
	var layer := get_layer(main)
	var valid: Array = []
	for id in ids:
		if layer != null and not layer.find_light(str(id)).is_empty():
			valid.append(str(id))
	if valid.is_empty():
		_drag = {}
		return []
	checkpoint(main)
	var targets := valid
	if duplicate:
		targets = duplicate_ids(main, valid, Vector3.ZERO)
		if targets.is_empty():
			_drag = {}
			return []
		set_selection(main, targets)
	_drag = {"ids": targets, "applied": Vector3.ZERO}
	return targets


static func is_dragging() -> bool:
	return not _drag.is_empty()


## Move the dragged light(s) so the total offset since begin_drag is `delta`.
static func drag_to(main: Node, delta: Vector3) -> void:
	if _drag.is_empty():
		return
	var step: Vector3 = delta - (_drag["applied"] as Vector3)
	if step.length_squared() < 1e-10:
		return
	_drag["applied"] = delta
	translate_ids(main, _drag["ids"], step)


static func end_drag(main: Node) -> void:
	if _drag.is_empty():
		return
	_drag = {}
	commit(main)


## Drop the drag (and any copy it made): back to the checkpoint, no redo entry.
static func cancel_drag(main: Node) -> void:
	if _drag.is_empty():
		return
	_drag = {}
	var layer := get_layer(main)
	if layer != null and not _undo.is_empty():
		layer.deserialize(_undo.pop_back())
		rebuild_all(main)
		notify()


# -- Edits (no checkpoint / save — callers wrap them) --------------------------

static func translate_ids(main: Node, ids: Array, delta: Vector3) -> void:
	var layer := get_layer(main)
	for id in ids:
		layer.translate_light(str(id), delta)
	refresh_ids(main, ids)


static func set_rotation(main: Node, id: String, rot: Vector3) -> void:
	get_layer(main).update_light(id, {"pitch": rot.x, "yaw": rot.y, "roll": rot.z})
	refresh_light(main, id)


static func set_waypoint(main: Node, id: String, index: int, pos: Vector3) -> void:
	var layer := get_layer(main)
	var pts := PlacedLightLayer.waypoints_of(layer.find_light(id))
	if index < 0 or index >= pts.size():
		return
	pts[index] = pos
	layer.set_waypoints(id, pts)
	refresh_light(main, id)


static func insert_waypoint(main: Node, id: String, after_index: int, pos: Vector3) -> int:
	var layer := get_layer(main)
	var pts := PlacedLightLayer.waypoints_of(layer.find_light(id))
	if pts.size() >= PlacedLightLayer.MAX_WAYPOINTS_PER_STRING:
		return -1
	var at := clampi(after_index + 1, 1, pts.size())
	pts.insert(at, pos)
	layer.set_waypoints(id, pts)
	refresh_light(main, id)
	return at


static func remove_waypoint(main: Node, id: String, index: int) -> bool:
	var layer := get_layer(main)
	var pts := PlacedLightLayer.waypoints_of(layer.find_light(id))
	if pts.size() <= 2 or index < 0 or index >= pts.size():
		return false
	pts.remove_at(index)
	layer.set_waypoints(id, pts)
	refresh_light(main, id)
	return true


## Write one style field for the given lights. into_style = edit the style
## (every user follows); else a per-light override.
static func set_field(main: Node, ids: Array, key: String, value: Variant, into_style: bool) -> void:
	var layer := get_layer(main)
	var touched_styles := {}
	for id in ids:
		var rec := layer.find_light(str(id))
		if rec.is_empty() or not PlacedLightStyles.is_style_key(str(rec["kind"]), key):
			continue
		layer.set_field(str(id), key, value, into_style)
		if into_style:
			touched_styles[str(rec["style_id"])] = true
	if into_style:
		for sid in touched_styles.keys():
			refresh_style_users(main, sid)
	else:
		refresh_ids(main, ids)


static func set_enabled(main: Node, ids: Array, on: bool) -> void:
	var layer := get_layer(main)
	for id in ids:
		layer.update_light(str(id), {"enabled": on})
	refresh_ids(main, ids)


# -- First-person wrappers (one gesture each) ---------------------------------

static func move_light_to(main: Node, id: String, pos: Vector3) -> void:
	var layer := get_layer(main)
	var rec := layer.find_light(id) if layer != null else {}
	if rec.is_empty():
		return
	checkpoint(main)
	translate_ids(main, [id], pos - layer.position_of(rec))
	commit(main)


static func move_waypoint(main: Node, id: String, index: int, pos: Vector3) -> void:
	if get_layer(main) == null:
		return
	checkpoint(main)
	set_waypoint(main, id, index, pos)
	commit(main)


# -- Styles / groups -----------------------------------------------------------

static func apply_style(main: Node, ids: Array, sid: String) -> void:
	var layer := get_layer(main)
	if not layer.styles.has(sid):
		return
	var kind := str(layer.styles[sid].get("kind", ""))
	for id in ids:
		var rec := layer.find_light(str(id))
		if not rec.is_empty() and str(rec["kind"]) == kind:
			rec["style_id"] = sid
			rec["overrides"] = {}
	active_style[kind] = sid
	refresh_ids(main, ids)


static func style_from_light(main: Node, id: String, style_name: String) -> String:
	var layer := get_layer(main)
	var rec := layer.find_light(id)
	if rec.is_empty():
		return ""
	var sid := layer.add_style(style_name, str(rec["kind"]), layer.resolved(rec))
	return sid


static func group_ids_of_kind(main: Node, kind: String) -> Array:
	var out: Array = []
	for r in get_layer(main).lights:
		if str(r["kind"]) == kind:
			out.append(str(r["id"]))
	return out


# -- Picking (pure ray maths over the built nodes — no colliders) ---------------

## Returns {type: "light"|"pin"|"wire"|"", id, index, t, point}.
static func pick(main: Node, ray_o: Vector3, ray_d: Vector3, want_wire: bool = true) -> Dictionary:
	var best := {"type": "", "id": "", "index": -1, "t": INF, "point": Vector3.ZERO}
	var layer := get_layer(main)
	if layer == null:
		return best
	for rec in layer.lights:
		var id := str(rec["id"])
		if str(rec["kind"]) == "string":
			var pts := PlacedLightLayer.waypoints_of(rec)
			for i in pts.size():
				var rp := LightGizmoMath.ray_point(ray_o, ray_d, pts[i])
				var t := float(rp["t"])
				if float(rp["dist"]) <= LightGizmoMath.pick_radius(0.3, t) and t < float(best["t"]):
					best = {"type": "pin", "id": id, "index": i, "t": t, "point": pts[i]}
		else:
			var p := layer.position_of(rec)
			var rp2 := LightGizmoMath.ray_point(ray_o, ray_d, p)
			var t2 := float(rp2["t"])
			if float(rp2["dist"]) <= LightGizmoMath.pick_radius(0.35, t2) and t2 < float(best["t"]):
				best = {"type": "light", "id": id, "index": -1, "t": t2, "point": p}
	if best["type"] != "" or not want_wire:
		return best
	# The wire itself, if no pin/light was closer.
	for rec in layer.lights:
		if str(rec["kind"]) != "string":
			continue
		var node := PlacedLightRuntime.find_node(main, str(rec["id"])) as PlacedStringLight
		if node == null:
			continue
		var pts2 := PlacedLightLayer.waypoints_of(rec)
		var ns := LightStringGeometry.nearest_span(pts2, node.samples, ray_o, ray_d)
		var t3 := float(ns["t"])
		if int(ns["span"]) >= 0 and float(ns["dist"]) <= LightGizmoMath.pick_radius(0.15, t3, 0.5) \
				and t3 < float(best["t"]):
			best = {"type": "wire", "id": str(rec["id"]), "index": int(ns["span"]), "t": t3,
				"point": ns["point"]}
	return best


# -- Graph (load only) ---------------------------------------------------------

static func add_to_graph(main: Node, id: String) -> bool:
	var layer := get_layer(main)
	var rec := layer.find_light(id)
	if rec.is_empty():
		return false
	var res := layer.resolved(rec)
	var watts := estimate_watts(main, rec, res)
	var label := str(rec.get("name", ""))
	if label.is_empty():
		label = layer.style_display_name(str(rec["style_id"]))
	var gid: Variant = _graph_call(main, "add_placed_light_load",
		[id, str(rec["kind"]), label, watts, layer.position_of(rec)])
	if gid == null or str(gid).is_empty():
		return false
	rec["graph_item_id"] = str(gid)
	rec["graph_watts"] = watts
	refresh_light(main, id)
	return true


static func remove_from_graph(main: Node, id: String) -> void:
	var layer := get_layer(main)
	var rec := layer.find_light(id)
	if rec.is_empty():
		return
	_graph_call(main, "remove_placed_light_load", [id])
	rec["graph_item_id"] = ""
	rec.erase("graph_watts")
	refresh_light(main, id)


## A string bills its preset's rated W/m over its measured length (rope, neon
## flex and festoon draw very differently per metre), falling back to the
## conduit kind's rate; a fixture its rated `watts`, else ~10 W per unit of
## energy (an LED flood at energy 1 is about 10 W).
static func estimate_watts(main: Node, rec: Dictionary, res: Dictionary) -> float:
	if str(rec["kind"]) == "string":
		var node := PlacedLightRuntime.find_node(main, str(rec["id"])) as PlacedStringLight
		var length := node.length_m if node != null else 0.0
		var wpm := float(res.get("watts_per_m", 0.0))
		if wpm <= 0.0:
			var meta := ConduitKinds.type_meta(PlacedLightStyles.conduit_kind_for(str(res.get("preset", "patio"))))
			wpm = float(meta.get("watts_per_m", 3.3))
		return snappedf(wpm * length, 0.1)
	var w := float(res.get("watts", 0.0))
	if w > 0.0:
		return w
	return snappedf(10.0 * float(res.get("energy", 1.0)), 0.1)


static func _graph_call(main: Node, method: String, args: Array) -> Variant:
	var gv := ServiceLocator.graph()
	if gv == null and main != null:
		gv = main.find_child("SystemGraphView", true, false)
	if gv == null or not gv.has_method(method):
		return null
	return gv.callv(method, args)

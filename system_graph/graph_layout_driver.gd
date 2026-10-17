class_name GraphLayoutDriver
extends RefCounted

## Runs GraphForceLayout on the live freeform canvas: the one-shot TIDY (an
## animated move to the settled layout, one undo step) and LIVE mode (the
## simulation keeps running; drag a node and the rest re-space around it).
##
## Positions are written straight onto the model's live item dicts while a
## layout animates — model.update_item would emit `changed` per node per frame
## and fire the view's whole telemetry / solar-sync / library cascade 60 times
## a second. `process()` reports when a settled layout should be COMMITTED (the
## view then pushes one history entry and schedules the autosave).
##
## A node with specs.layout_pinned never moves; the node being dragged is
## pinned for the length of the drag.

const TIDY_ANIM_S := 0.45
## Per-frame CPU budget for Live stepping.
const LIVE_BUDGET_USEC := 1500
## Fresh-heat after a structural edit / at the end of a drag.
const REHEAT_EDIT := 0.5
const REHEAT_DRAG := 0.3

var model: GraphModel = null
var canvas: Control = null
## Callable(item, handle_id) -> float (port's vertical position on its card).
var port_side: Callable = Callable()
var params: Dictionary = GraphForceLayout.default_params()
var live := false

var _sim: GraphForceLayout = null
var _sim_scope := ""
var _dirty := true
var _moved_since_commit := false
var _drag_pins: Dictionary = {}

var _anim_from: Dictionary = {}
var _anim_to: Dictionary = {}
var _anim_t := -1.0
var _anim_commit := false


func is_animating() -> bool:
	return _anim_t >= 0.0


## Where a running Tidy is taking each node ({} when nothing animates).
func animation_target() -> Dictionary:
	return _anim_to if _anim_t >= 0.0 else {}


## Mark the graph's structure changed (node / wire added or removed).
func mark_dirty() -> void:
	_dirty = true


func set_params(p: Dictionary) -> void:
	params = p.duplicate()
	_dirty = true


func set_live(on: bool) -> void:
	live = on
	_dirty = true
	if not on:
		_sim = null


## Items in `scope_id` the layout moves (virtual / tray items excluded), as
## LAYOUT copies: a round tank /
## catchment draws its name as a caption BESIDE the circle when it does not fit
## inside, so its layout box is widened by that caption — otherwise Tidy packs
## two intakes side by side and their captions overprint.
func scope_items(scope_id: String) -> Array:
	if model == null:
		return []
	var out: Array = []
	# A show-only view (Power, Water…) lays out only what it shows; hidden
	# nodes keep their place.
	var shown: Dictionary = {}
	if canvas != null and canvas.has_method("domain_visible_ids"):
		shown = canvas.call("domain_visible_ids")
	for it in GraphLayout.filter_layout_items(model.get_items_in_scope(scope_id)):
		var d: Dictionary = it
		if not shown.is_empty() and not shown.has(str(d.get("id", ""))):
			continue
		var t := str(d.get("type", ""))
		if t in ["resource", "catchment"]:
			var nm := GraphPortLabels.node_name(d)
			var w := float(d.get("width", 120.0))
			var h := float(d.get("height", 90.0))
			if nm.length() * 6.5 > minf(w, h) * 0.8:
				d = d.duplicate()
				d["width"] = w + nm.length() * 6.5 + 8.0
		out.append(d)
	return out


## The scope's connections whose both ends are among `items`.
func _conns_between(scope_id: String, items: Array) -> Array:
	var ids := {}
	for it in items:
		ids[str((it as Dictionary).get("id", ""))] = true
	var out: Array = []
	for c in model.get_connections_in_scope(scope_id):
		var cd: Dictionary = c
		if ids.has(str(cd.get("source_item_id", ""))) and ids.has(str(cd.get("target_item_id", ""))):
			out.append(cd)
	return out


func pinned_ids(items: Array) -> Dictionary:
	var out := {}
	for it in items:
		var d: Dictionary = it
		if bool((d.get("specs", {}) as Dictionary).get("layout_pinned", false)):
			out[str(d.get("id", ""))] = true
	return out


## Compute the settled layout for `scope_id` and glide every node to it.
## Returns false when there is nothing to arrange.
func tidy(scope_id: String, animate: bool = true) -> bool:
	var items := scope_items(scope_id)
	if items.size() < 2:
		return false
	var conns: Array = _conns_between(scope_id, items)
	var target: Dictionary
	var groups := pv_groups(scope_id, items)
	if groups.is_empty():
		target = GraphForceLayout.tidy(items, conns, port_side, params, pinned_ids(items))
	else:
		# A solar array's panels move as ONE block: collapse each array to its
		# bounding box, lay that out, then put every panel back at its offset.
		var col := _collapse_groups(items, conns, groups, scope_id)
		target = GraphForceLayout.tidy(col["items"], col["conns"], Callable(self, "_group_port_side"),
			params, pinned_ids(col["items"]))
		for gid in groups:
			if not target.has(gid):
				continue
			var base: Vector2 = target[gid]
			for mid in groups[gid]:
				target[mid] = base + (col["offsets"][mid] as Vector2)
			target.erase(gid)
	_anim_from = {}
	_anim_to = target
	for it in items:
		var d: Dictionary = it
		_anim_from[str(d["id"])] = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	_anim_commit = true
	if animate:
		_anim_t = 0.0
	else:
		_write_positions(_anim_to)
		_anim_t = -1.0
		_moved_since_commit = true
	_dirty = true
	return true


## Per frame. Returns true when a finished layout change should be committed.
func process(delta: float, scope_id: String, freeform: bool) -> bool:
	if model == null:
		return false
	if _anim_t >= 0.0:
		_anim_t += delta
		var k := clampf(_anim_t / TIDY_ANIM_S, 0.0, 1.0)
		var e := 1.0 - pow(1.0 - k, 3.0)
		var frame := {}
		for iid in _anim_to:
			var from: Vector2 = _anim_from.get(iid, _anim_to[iid])
			frame[iid] = from.lerp(_anim_to[iid] as Vector2, e)
		_write_positions(frame)
		if k >= 1.0:
			_anim_t = -1.0
			if live:
				_dirty = true   # Live continues from the tidied layout
			if _anim_commit:
				_anim_commit = false
				return true
		return false
	if not live or not freeform:
		return false
	if _sim == null or _dirty or scope_id != _sim_scope:
		_rebuild(scope_id)
	if _sim == null:
		return false
	var dragging := _dragged_ids()
	for iid in _drag_pins.keys():
		if not dragging.has(iid):
			_drag_pins.erase(iid)
			_sim.set_pinned(str(iid), _is_spec_pinned(str(iid)))
			_sim.reheat(REHEAT_DRAG)
	for iid in dragging:
		var it := model.get_item(str(iid))
		if it.is_empty():
			continue
		if not _drag_pins.has(iid):
			_drag_pins[iid] = true
			_sim.set_pinned(str(iid), true)
		var sz := Vector2(float(it.get("width", 120.0)), float(it.get("height", 90.0)))
		_sim.set_center(str(iid), Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0))) + sz * 0.5)
		_sim.reheat(REHEAT_DRAG)
	if _sim.is_settled():
		if _moved_since_commit and dragging.is_empty():
			_moved_since_commit = false
			return true
		return false
	var t0 := Time.get_ticks_usec()
	while not _sim.is_settled() and Time.get_ticks_usec() - t0 < LIVE_BUDGET_USEC:
		_sim.step()
	var pos := _sim.positions()
	for iid in dragging:
		pos.erase(iid)
	_write_positions(pos)
	_moved_since_commit = true
	return false


## Toggle specs.layout_pinned on `ids` (one model write each — this IS an edit).
func set_pinned(ids: Array, on: bool) -> void:
	for iid in ids:
		var it := model.get_item(str(iid))
		if it.is_empty():
			continue
		var sp: Dictionary = (it.get("specs", {}) as Dictionary).duplicate()
		if on:
			sp["layout_pinned"] = true
		else:
			sp.erase("layout_pinned")
		model.update_item(str(iid), {"specs": sp})
		if _sim != null:
			_sim.set_pinned(str(iid), on)
	_dirty = true


func _rebuild(scope_id: String) -> void:
	_dirty = false
	_sim_scope = scope_id
	var items := scope_items(scope_id)
	if items.size() < 2:
		_sim = null
		return
	var keep_alpha := _sim.alpha if _sim != null else 1.0
	_sim = GraphForceLayout.new()
	_sim.configure(params)
	var pins := pinned_ids(items)
	# Live layout leaves a lined-up solar array where it is (Tidy moves it as a
	# block); the panels would otherwise drift out of their grid.
	var groups := pv_groups(scope_id, items)
	for gid in groups:
		for mid in groups[gid]:
			pins[str(mid)] = true
	_sim.setup(items, _conns_between(scope_id, items), port_side, pins)
	# A rebuild after an edit warms the layout; a first build starts hot.
	_sim.alpha = maxf(REHEAT_EDIT, keep_alpha) if keep_alpha < 1.0 else 1.0
	for iid in _drag_pins:
		_sim.set_pinned(str(iid), true)


func _is_spec_pinned(iid: String) -> bool:
	var it := model.get_item(iid)
	return bool((it.get("specs", {}) as Dictionary).get("layout_pinned", false)) if not it.is_empty() else false


func _dragged_ids() -> Array:
	if canvas == null or not bool(canvas.get("_item_dragging")):
		return []
	var ids: Variant = canvas.get("_item_drag_ids")
	return (ids as Array) if ids is Array else []


func _write_positions(pos: Dictionary) -> void:
	for iid in pos:
		var it := model.get_item(str(iid))
		if it.is_empty():
			continue
		var p: Vector2 = pos[iid]
		it["x"] = p.x
		it["y"] = p.y
	if canvas != null:
		canvas.queue_redraw()



## Solar arrays to keep rigid: panels feeding one controller, two or more,
## while the canvas's PV grid snap is on. {"pvgrp:<controller>": [panel ids]}.
func pv_groups(scope_id: String, items: Array) -> Dictionary:
	var out := {}
	if canvas == null or not bool(canvas.get("pv_snap_enabled")):
		return out
	var present := {}
	for it in items:
		var d: Dictionary = it
		if str(d.get("type", "")) == "panel":
			present[str(d.get("id", ""))] = true
	if present.size() < 2:
		return out
	var keys := GraphPvWiring.array_keys(model, scope_id)
	for pid in present.keys():
		var k := str(keys.get(pid, ""))
		if k.is_empty():
			continue
		var gid := "pvgrp:" + k
		if not out.has(gid):
			out[gid] = []
		(out[gid] as Array).append(pid)
	for gid in out.keys():
		if (out[gid] as Array).size() < 2:
			out.erase(gid)
	return out


## Items with each group replaced by one box item, connections re-pointed at
## the box (wires inside a group dropped), and each member's offset from the
## box's top-left.
func _collapse_groups(items: Array, conns: Array, groups: Dictionary, scope_id: String = "root") -> Dictionary:
	var member_of := {}
	for gid in groups:
		for mid in groups[gid]:
			member_of[str(mid)] = gid
	var boxes := {}
	var out_items: Array = []
	for it in items:
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		if not member_of.has(iid):
			out_items.append(d)
			continue
		var gid: String = member_of[iid]
		var r := Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
			float(d.get("width", 120.0)), float(d.get("height", 90.0)))
		boxes[gid] = (boxes[gid] as Rect2).merge(r) if boxes.has(gid) else r
	var offsets := {}
	var gap := float(canvas.get("pv_snap_gap_px")) if canvas != null else 24.0
	for gid in groups:
		var b: Rect2 = boxes[gid]
		var pinned := false
		# Inside the block the array is a clean grid: one row per series
		# string, in chain order (Tidy is the auto-snap for a whole array).
		var gw := 0.0
		var gy := 0.0
		for row in GraphPvWiring.string_rows(model, groups[gid], scope_id):
			var gx := 0.0
			var rh := 0.0
			for mid in row:
				var m := model.get_item(str(mid))
				offsets[str(mid)] = Vector2(gx, gy)
				gx += float(m.get("width", 120.0)) + gap
				rh = maxf(rh, float(m.get("height", 90.0)))
				if bool((m.get("specs", {}) as Dictionary).get("layout_pinned", false)):
					pinned = true
			gw = maxf(gw, gx - gap)
			gy += rh + gap + 4.0
		b.size = Vector2(maxf(gw, 1.0), maxf(gy - gap - 4.0, 1.0))
		out_items.append({"id": gid, "type": "panel", "x": b.position.x, "y": b.position.y,
			"width": b.size.x, "height": b.size.y, "_pv_members": groups[gid],
			"specs": {"layout_pinned": pinned}})
	var out_conns: Array = []
	for c in conns:
		var cd: Dictionary = (c as Dictionary).duplicate()
		var a := str(cd.get("source_item_id", ""))
		var b2 := str(cd.get("target_item_id", ""))
		if member_of.has(a):
			cd["source_item_id"] = member_of[a]
		if member_of.has(b2):
			cd["target_item_id"] = member_of[b2]
		if str(cd["source_item_id"]) == str(cd["target_item_id"]):
			continue
		out_conns.append(cd)
	return {"items": out_items, "conns": out_conns, "offsets": offsets}


## Port side for a collapsed array box: the side of that port on its panels.
func _group_port_side(item: Dictionary, handle_id: String) -> float:
	if item.has("_pv_members") and not (item["_pv_members"] as Array).is_empty():
		return float(port_side.call(model.get_item(str((item["_pv_members"] as Array)[0])), handle_id)) \
			if port_side.is_valid() else NAN
	return float(port_side.call(item, handle_id)) if port_side.is_valid() else NAN

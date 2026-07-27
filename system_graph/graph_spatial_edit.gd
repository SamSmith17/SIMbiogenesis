class_name GraphSpatialEdit
extends RefCounted

## Site Plan / Elevation spatial edit seam — pick & drag 3D props (and later
## buildings / veg / terrain) without going through 2D graph chips.
## Owned by SystemGraphView; canvas routes Site/Elev presses here first.

enum Tool {
	NONE,
	PROP_MOVE,
	ARRAY,
	## Reserved for later Site Plan expansion.
	BUILDING,
	VEG_PAINT,
	TERRAIN,
	RADIAL,
}

enum ArrayPattern {
	LINE,
	ARC,
	CIRCLE,
}

signal selection_changed(prop_id: String)
signal working_radius_changed(radius_m: float)
signal array_preview_changed()

var tool: int = Tool.PROP_MOVE
var selected_prop_id: String = ""
var hover_prop_id: String = ""

## Working radius for radial guides / array (independent of SoI radius).
var working_radius_m: float = NAN
## Custom array/radial center in site metres (NAN = SoI origin).
var custom_center_site: Vector2 = Vector2(NAN, NAN)

var array_pattern: int = ArrayPattern.CIRCLE
var array_count: int = 6
## Line spacing (m) or arc/circle angular step override (deg; ≤0 → even split).
var array_spacing_m: float = 4.0
var array_angle_deg: float = 0.0
var array_active: bool = false
var array_ghosts: Array = []  # Array of {site_x_m, site_z_m, yaw_deg}

var _dragging: bool = false
var _drag_prop_id: String = ""
var _drag_start_canvas: Vector2 = Vector2.ZERO
var _drag_start_world_xz: Vector2 = Vector2.ZERO
var _shift_yaw_active: bool = false
## Current dragged prop position in site metres (for the radial-guide overlay).
var _drag_site: Vector2 = Vector2.ZERO

## View owner callbacks (set by SystemGraphView).
var get_main: Callable = Callable()
var get_preview: Callable = Callable()
var get_view_mode: Callable = Callable()
var get_elev_heading: Callable = Callable()
var get_conduit_manager: Callable = Callable()
var sync_graph_from_prop: Callable = Callable()
var on_highlight: Callable = Callable()
## Hovered conduit connection id (3D pick when no prop under cursor).
var hover_conduit_id: String = ""


static func radial_tangent_yaw_deg(site_xz: Vector2, center_site: Vector2 = Vector2.ZERO) -> float:
	var rel := site_xz - center_site
	if rel.length() < 0.5:
		return 0.0
	var theta := atan2(rel.y, rel.x)
	# Face outward; width along tangent (matches existing Site Plan radial math).
	return rad_to_deg(-(theta + PI * 0.5))


func ensure_working_radius(soi_radius_m: float) -> float:
	if is_nan(working_radius_m) or working_radius_m < 1.0:
		working_radius_m = maxf(soi_radius_m, 5.0)
	return working_radius_m


func set_working_radius(r_m: float, soi_radius_m: float = 150.0) -> void:
	working_radius_m = clampf(r_m, 2.0, maxf(soi_radius_m * 1.5, 10.0))
	working_radius_changed.emit(working_radius_m)


func reset_working_radius_to_soi(soi_radius_m: float) -> void:
	set_working_radius(soi_radius_m, soi_radius_m)


func radial_center_site() -> Vector2:
	if is_nan(custom_center_site.x) or is_nan(custom_center_site.y):
		return Vector2.ZERO
	return custom_center_site


func clear_custom_center() -> void:
	custom_center_site = Vector2(NAN, NAN)


func is_dragging() -> bool:
	return _dragging


## Shift-held (radial tangent-align) during the active prop drag.
func drag_shift_active() -> bool:
	return _dragging and _shift_yaw_active


## Current dragged prop position in site metres (for the radial-guide overlay).
func drag_prop_site() -> Vector2:
	return _drag_site


func cancel_drag() -> void:
	_dragging = false
	_drag_prop_id = ""
	_shift_yaw_active = false


## Returns {kind:"prop"|"conduit", id, world:Vector3} or {}.
func pick_at_canvas(canvas_pos: Vector2) -> Dictionary:
	var preview: Node = get_preview.call() if get_preview.is_valid() else null
	var main: Node = get_main.call() if get_main.is_valid() else null
	if preview == null or main == null:
		return {}
	if not preview.has_method("canvas_ray"):
		return {}
	var ray: Variant = preview.call("canvas_ray", canvas_pos)
	if not (ray is Dictionary):
		return {}
	var ro: Vector3 = (ray as Dictionary).get("origin", Vector3.ZERO)
	var rn: Vector3 = (ray as Dictionary).get("normal", Vector3.FORWARD)
	if rn.length_squared() < 1e-8:
		return {}
	rn = rn.normalized()
	var best_id := ""
	var best_t := 1.0e9
	var best_world := Vector3.ZERO
	var parent := main.get_node_or_null("PlacedProps")
	if parent == null:
		parent = main.find_child("PlacedProps", true, false)
	if parent != null:
		for child in parent.get_children():
			if not (child is PlacedProp):
				continue
			var pp := child as PlacedProp
			var aabb: AABB = pp.get_world_pick_aabb()
			if aabb.size.length_squared() < 1e-6:
				continue
			# Inflate for top-down/ortho picks; Elevation section needs more slack
			# (hydroturbine / thin props miss a tight AABB behind the cut plane).
			var mode := str(get_view_mode.call()) if get_view_mode.is_valid() else ""
			var grow_m := 1.25 if (mode == "elevation" or mode == "siphon") else 0.35
			aabb = aabb.grow(grow_m)
			var hit: Variant = aabb.intersects_ray(ro, rn)
			if not (hit is Vector3):
				continue
			var hw: Vector3 = hit as Vector3
			var t := (hw - ro).dot(rn)
			if t < 0.0 or t >= best_t:
				continue
			best_t = t
			best_id = str(pp.prop_id)
			best_world = hw
	if not best_id.is_empty():
		return {"kind": "prop", "id": best_id, "world": best_world}
	# No prop — try 3D conduit polyline pick (Site prefer_3d / Elev CT).
	var mgr: Node = get_conduit_manager.call() if get_conduit_manager.is_valid() else null
	if mgr != null and mgr.has_method("pick_conduit"):
		var chit: Dictionary = mgr.call("pick_conduit", ro, rn) as Dictionary
		var cid := str(chit.get("conn_id", ""))
		var cdist := float(chit.get("distance", INF))
		if not cid.is_empty() and is_finite(cdist) and cdist < 2.5:
			return {
				"kind": "conduit",
				"id": cid,
				"world": chit.get("point", Vector3.ZERO) as Vector3,
				"distance": cdist,
			}
	return {}


func set_hover(prop_id: String) -> void:
	if hover_prop_id == prop_id:
		return
	hover_prop_id = prop_id
	var show_id := prop_id if not prop_id.is_empty() else selected_prop_id
	if on_highlight.is_valid():
		on_highlight.call(show_id)


func select_prop(prop_id: String) -> void:
	selected_prop_id = prop_id
	selection_changed.emit(prop_id)
	if on_highlight.is_valid():
		on_highlight.call(prop_id)


## Begin prop drag. Returns true if consumed.
func begin_prop_drag(canvas_pos: Vector2, shift_held: bool) -> bool:
	var hit := pick_at_canvas(canvas_pos)
	if hit.is_empty() or str(hit.get("kind", "")) != "prop":
		return false
	var pid := str(hit.get("id", ""))
	return begin_prop_drag_id(pid, canvas_pos, shift_held, hit.get("world", Vector3.ZERO) as Vector3)


## Begin drag for a known prop id (Elevation fallback when ray pick misses).
func begin_prop_drag_id(prop_id: String, canvas_pos: Vector2,
		shift_held: bool = false, world_hint: Vector3 = Vector3.ZERO) -> bool:
	if prop_id.is_empty():
		return false
	select_prop(prop_id)
	_dragging = true
	_drag_prop_id = prop_id
	_drag_start_canvas = canvas_pos
	if world_hint != Vector3.ZERO:
		_drag_start_world_xz = Vector2(world_hint.x, world_hint.z)
	else:
		var main: Node = get_main.call() if get_main.is_valid() else null
		var xz := Vector2.ZERO
		if main != null:
			var parent := main.get_node_or_null("PlacedProps")
			if parent == null:
				parent = main.find_child("PlacedProps", true, false)
			if parent != null:
				for child in parent.get_children():
					if child is PlacedProp and str((child as PlacedProp).prop_id) == prop_id:
						var gt: Transform3D = (child as Node3D).global_transform
						xz = Vector2(gt.origin.x, gt.origin.z)
						break
		_drag_start_world_xz = xz
	_shift_yaw_active = shift_held
	tool = Tool.PROP_MOVE
	return true


## Update hover when not dragging. Returns true if a prop/conduit is under cursor.
func update_hover(canvas_pos: Vector2) -> bool:
	if _dragging:
		return true
	var hit := pick_at_canvas(canvas_pos)
	var kind := str(hit.get("kind", ""))
	if kind == "prop":
		hover_conduit_id = ""
		var pid := str(hit.get("id", ""))
		set_hover(pid)
		_highlight_conduit("")
		return not pid.is_empty()
	set_hover("")
	if kind == "conduit":
		hover_conduit_id = str(hit.get("id", ""))
		_highlight_conduit(hover_conduit_id)
		return not hover_conduit_id.is_empty()
	hover_conduit_id = ""
	_highlight_conduit("")
	return false


func _highlight_conduit(conn_id: String) -> void:
	var mgr: Node = get_conduit_manager.call() if get_conduit_manager.is_valid() else null
	if mgr != null and mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", conn_id)


## Drag move. Returns true if consumed.
func drag_to(canvas_pos: Vector2, shift_held: bool) -> bool:
	if not _dragging or _drag_prop_id.is_empty():
		return false
	_shift_yaw_active = shift_held
	var main: Node = get_main.call() if get_main.is_valid() else null
	var preview: Node = get_preview.call() if get_preview.is_valid() else null
	if main == null or preview == null:
		return true
	var mode := str(get_view_mode.call()) if get_view_mode.is_valid() else ""
	var elev_plane := mode == "elevation" or mode == "siphon"
	var soi := main.get_tree().root.get_node_or_null("SoiService") if main.get_tree() else null
	var center := Vector3.ZERO
	if soi != null and soi.has_method("world_center"):
		center = soi.call("world_center") as Vector3
	var wx := NAN
	var wz := NAN
	var elev_m := NAN
	if elev_plane and preview.has_method("canvas_to_elevation_hit"):
		var heading := float(get_elev_heading.call()) if get_elev_heading.is_valid() else 0.0
		var e: Variant = preview.call("canvas_to_elevation_hit", canvas_pos, heading)
		if e is Dictionary:
			wx = center.x + float((e as Dictionary).get("site_x_m", 0.0))
			wz = center.z + float((e as Dictionary).get("site_z_m", 0.0))
			elev_m = float((e as Dictionary).get("elevation_m", NAN))
	elif preview.has_method("canvas_to_site_ground"):
		var s: Variant = preview.call("canvas_to_site_ground", canvas_pos)
		if s is Vector2:
			wx = center.x + (s as Vector2).x
			wz = center.z + (s as Vector2).y
	if is_nan(wx) or is_nan(wz):
		return true
	# Elevation / Hydro Lab: lock to cut plane; pin footing Y to the hit elev.
	if elev_plane and not is_nan(elev_m):
		PlacedPropService.move_prop_at(main, _drag_prop_id, wx, wz, elev_m)
	else:
		PlacedPropService.move_prop_xz(main, _drag_prop_id, wx, wz)
	_drag_site = Vector2(wx - center.x, wz - center.z)  # for the radial overlay
	if shift_held or _shift_yaw_active:
		var yaw := radial_tangent_yaw_deg(_drag_site, radial_center_site())
		PlacedPropService.update_prop_record(main, _drag_prop_id, {"yaw": yaw}, true)
	if not is_nan(elev_m) and sync_graph_from_prop.is_valid():
		sync_graph_from_prop.call(_drag_prop_id, {"elevation_m": elev_m})
	elif sync_graph_from_prop.is_valid():
		sync_graph_from_prop.call(_drag_prop_id, {})
	return true


func end_prop_drag() -> bool:
	if not _dragging:
		return false
	_dragging = false
	var pid := _drag_prop_id
	_drag_prop_id = ""
	_shift_yaw_active = false
	if sync_graph_from_prop.is_valid() and not pid.is_empty():
		sync_graph_from_prop.call(pid, {})
	return true


func begin_array_from_selection() -> bool:
	if selected_prop_id.is_empty():
		return false
	array_active = true
	tool = Tool.ARRAY
	rebuild_array_ghosts()
	return true


func cancel_array() -> void:
	array_active = false
	array_ghosts.clear()
	tool = Tool.PROP_MOVE
	array_preview_changed.emit()


func rebuild_array_ghosts() -> void:
	array_ghosts.clear()
	if not array_active or selected_prop_id.is_empty():
		array_preview_changed.emit()
		return
	var main: Node = get_main.call() if get_main.is_valid() else null
	if main == null:
		return
	var rec := PlacedPropService.get_prop_record(main, selected_prop_id)
	if rec.is_empty():
		return
	var soi := main.get_tree().root.get_node_or_null("SoiService") if main.get_tree() else null
	var center3 := Vector3.ZERO
	if soi != null and soi.has_method("world_center"):
		center3 = soi.call("world_center") as Vector3
	var origin_site := radial_center_site()
	var src_site := Vector2(float(rec.get("x", 0.0)) - center3.x,
			float(rec.get("z", 0.0)) - center3.z)
	var n := maxi(array_count, 2)
	var r := src_site.distance_to(origin_site)
	if r < 0.5:
		r = ensure_working_radius(150.0)
	match array_pattern:
		ArrayPattern.LINE:
			var dir := (src_site - origin_site)
			if dir.length() < 0.1:
				dir = Vector2(1.0, 0.0)
			else:
				dir = dir.normalized()
			# Perpendicular for a camp "row" across the radial.
			var along := Vector2(-dir.y, dir.x)
			for i in range(n):
				var offset := (float(i) - float(n - 1) * 0.5) * array_spacing_m
				var p := src_site + along * offset
				array_ghosts.append({
					"site_x_m": p.x,
					"site_z_m": p.y,
					"yaw_deg": radial_tangent_yaw_deg(p, origin_site),
					"is_source": is_zero_approx(offset),
				})
		ArrayPattern.ARC:
			var span := array_angle_deg if array_angle_deg > 1.0 else 90.0
			var a0 := atan2(src_site.y - origin_site.y, src_site.x - origin_site.x)
			var half := deg_to_rad(span) * 0.5
			for i in range(n):
				var t := 0.0 if n <= 1 else float(i) / float(n - 1)
				var ang := a0 - half + t * half * 2.0
				var p := origin_site + Vector2(cos(ang), sin(ang)) * r
				array_ghosts.append({
					"site_x_m": p.x,
					"site_z_m": p.y,
					"yaw_deg": radial_tangent_yaw_deg(p, origin_site),
					"is_source": i == int(round(float(n - 1) * 0.5)),
				})
		ArrayPattern.CIRCLE:
			var a0c := atan2(src_site.y - origin_site.y, src_site.x - origin_site.x)
			for i in range(n):
				var ang := a0c + TAU * float(i) / float(n)
				var p := origin_site + Vector2(cos(ang), sin(ang)) * r
				array_ghosts.append({
					"site_x_m": p.x,
					"site_z_m": p.y,
					"yaw_deg": radial_tangent_yaw_deg(p, origin_site),
					"is_source": i == 0,
				})
	array_preview_changed.emit()


## Place duplicates for non-source ghosts. Prop-only (no graph twin clone).
func confirm_array() -> int:
	if not array_active or array_ghosts.is_empty():
		return 0
	var main: Node = get_main.call() if get_main.is_valid() else null
	if main == null:
		return 0
	var rec := PlacedPropService.get_prop_record(main, selected_prop_id)
	if rec.is_empty():
		return 0
	var model_id := str(rec.get("model_id", ""))
	if model_id.is_empty():
		return 0
	var soi := main.get_tree().root.get_node_or_null("SoiService") if main.get_tree() else null
	var center3 := Vector3.ZERO
	if soi != null and soi.has_method("world_center"):
		center3 = soi.call("world_center") as Vector3
	var placed := 0
	for g in array_ghosts:
		if not (g is Dictionary):
			continue
		if bool((g as Dictionary).get("is_source", false)):
			continue
		var sx := float((g as Dictionary).get("site_x_m", 0.0))
		var sz := float((g as Dictionary).get("site_z_m", 0.0))
		var yaw := float((g as Dictionary).get("yaw_deg", 0.0))
		var wx := center3.x + sx
		var wz := center3.z + sz
		var r: Dictionary = PlacedPropService.place_model_at_xz(
				main, model_id, wx, wz, {"yaw": yaw})
		if bool(r.get("ok", false)):
			placed += 1
	cancel_array()
	return placed


func to_prefs() -> Dictionary:
	# JSON has no NaN — omit / use null so apply_prefs doesn't see null→float().
	var center_pref: Variant = null
	if not is_nan(custom_center_site.x) and not is_nan(custom_center_site.y):
		center_pref = [custom_center_site.x, custom_center_site.y]
	var radius_pref: Variant = null
	if not is_nan(working_radius_m):
		radius_pref = working_radius_m
	return {
		"working_radius_m": radius_pref,
		"custom_center_site": center_pref,
		"array_pattern": array_pattern,
		"array_count": array_count,
		"array_spacing_m": array_spacing_m,
		"array_angle_deg": array_angle_deg,
	}


func apply_prefs(data: Dictionary) -> void:
	if data.is_empty():
		return
	if data.has("working_radius_m"):
		working_radius_m = _pref_float(data.get("working_radius_m"), NAN)
	if data.has("custom_center_site"):
		var cc: Variant = data.get("custom_center_site")
		if cc is Array and (cc as Array).size() >= 2:
			var arr: Array = cc
			custom_center_site = Vector2(
					_pref_float(arr[0], NAN), _pref_float(arr[1], NAN))
		else:
			custom_center_site = Vector2(NAN, NAN)
	array_pattern = int(data.get("array_pattern", array_pattern))
	array_count = int(data.get("array_count", array_count))
	array_spacing_m = _pref_float(data.get("array_spacing_m"), array_spacing_m)
	array_angle_deg = _pref_float(data.get("array_angle_deg"), array_angle_deg)


## JSON null / missing → fallback. Avoids Godot 4.6 `float(null)` hard error
## ("Nonexistent 'float' constructor") after NaN prefs round-trip.
static func _pref_float(v: Variant, fallback: float) -> float:
	if v == null:
		return fallback
	match typeof(v):
		TYPE_FLOAT:
			return v
		TYPE_INT:
			return float(v)
		TYPE_STRING:
			var s := str(v)
			if s.is_empty() or s.to_lower() == "nan" or s.to_lower() == "null":
				return fallback
			return s.to_float()
		_:
			return fallback

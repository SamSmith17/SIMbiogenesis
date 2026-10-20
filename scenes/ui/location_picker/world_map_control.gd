extends Control
class_name WorldMapControl
## Equirectangular 2:1 world map: zone-tinted land, coastlines, optional KML, selection marker.
signal location_selected(lat: float, lng: float)

const GRID_STEP: float = 1.0
const GRID_COLS: int = 360
const GRID_ROWS: int = 180
const ZONE_UNFOCUSED: float = 0.07
const ZONE_KML_ALPHA: float = 0.85
const MIN_ZOOM: float = 1.0
const MAX_ZOOM: float = 56.0
const ZOOM_WHEEL: float = 1.12
const OCEAN_COLOR := Color(0.06, 0.09, 0.16, 1.0)

@export var focus_zone_id: int = -1 : set = set_focus_zone_id
## (lng, lat) or (INF, INF) = no selection
var _selected_geo: Vector2 = Vector2(INF, INF)
var kml_text: String = "" : set = set_kml_text
var kml_placemarks: Array[Dictionary] = []
var _topo: TopojsonLoader
var _zone_id_cache: PackedByteArray = PackedByteArray()
var _zone_base_img: Image
var _tint_tex: ImageTexture = null
var _tint_focus: int = -999
var _on_land_built: bool = false
var _css_w: float = 400.0
var _css_h: float = 200.0
var _zoom: float = 1.0
var _view_lng: float = 0.0
var _view_lat: float = 0.0
var _panning: bool = false
var _pan_mouse_start: Vector2 = Vector2.ZERO
var _pan_view_start: Vector2 = Vector2.ZERO
var G: GhiService

const ZONES_FALL: Array[Dictionary] = [
	{"id": 1, "color": Color("#313695")},
	{"id": 2, "color": Color("#74add1")},
	{"id": 3, "color": Color("#fee090")},
	{"id": 4, "color": Color("#fdae61")},
	{"id": 5, "color": Color("#f46d43")},
	{"id": 6, "color": Color("#a50026")},
]

func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		G = get_node_or_null("/root/GhiService") as GhiService

func _ready() -> void:
	if not Engine.is_editor_hint():
		G = get_node_or_null("/root/GhiService") as GhiService
	clip_contents = true
	custom_minimum_size = Vector2(400, 200)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_topo = TopojsonLoader.new()
	if not _topo.load_from_path():
		push_warning("WorldMapControl: could not load countries-110m.json")
	if is_instance_valid(G) and not G.ghi_data_ready.is_connected(_on_ghi_ready):
		G.ghi_data_ready.connect(_on_ghi_ready, CONNECT_DEFERRED)
	_rebuild_data()
	if (not is_instance_valid(G) or G == null) and not Engine.is_editor_hint():
		call_deferred("_rebuild_data")
	resized.connect(queue_redraw)

func _on_ghi_ready() -> void:
	_rebuild_data()
	queue_redraw()

func set_focus_zone_id(v: int) -> void:
	if focus_zone_id == v:
		return
	focus_zone_id = v
	_tint_focus = -999
	queue_redraw()

func set_kml_text(t: String) -> void:
	kml_text = t
	if t.is_empty():
		kml_placemarks = []
	else:
		kml_placemarks = KmlParser.parse_kml(t)
	_rebuild_data()
	queue_redraw()

func set_selection_lat_lng(lat: float, lng: float) -> void:
	_selected_geo = Vector2(lng, lat)
	queue_redraw()

func clear_selection() -> void:
	_selected_geo = Vector2(INF, INF)
	queue_redraw()

func reset_view() -> void:
	_zoom = 1.0
	_view_lng = 0.0
	_view_lat = 0.0
	queue_redraw()

func _view_half_extents() -> Vector2:
	return Vector2(180.0 / _zoom, 90.0 / _zoom)

func _view_bounds() -> Dictionary:
	var half := _view_half_extents()
	return {
		"lng_min": _view_lng - half.x,
		"lng_max": _view_lng + half.x,
		"lat_min": _view_lat - half.y,
		"lat_max": _view_lat + half.y,
	}

func _clamp_view() -> void:
	if _zoom <= MIN_ZOOM + 0.001:
		_zoom = MIN_ZOOM
		_view_lng = 0.0
		_view_lat = 0.0
		return
	var half := _view_half_extents()
	_view_lng = clampf(_view_lng, -180.0 + half.x, 180.0 - half.x)
	_view_lat = clampf(_view_lat, -90.0 + half.y, 90.0 - half.y)

func _rebuild_data() -> void:
	_on_land_built = false
	_zone_id_cache = PackedByteArray()
	_zone_base_img = null
	_tint_tex = null
	_tint_focus = -999
	if G == null:
		G = get_node_or_null("/root/GhiService") as GhiService
	if not _topo.is_loaded():
		return
	if not kml_text.is_empty() and not kml_placemarks.is_empty():
		_on_land_built = _topo.is_loaded()
		return
	if G == null:
		return
	_zone_id_cache.resize(GRID_ROWS * GRID_COLS)
	_zone_base_img = Image.create(GRID_COLS, GRID_ROWS, false, Image.FORMAT_RGBA8)
	_zone_base_img.fill(Color(0, 0, 0, 0))
	var idx: int = 0
	var lat0: float = -90.0
	while lat0 < 90.0 - 0.001:
		var lng0: float = -180.0
		while lng0 < 180.0 - 0.001:
			var cell_mid_lat: float = lat0 + GRID_STEP * 0.5
			var cx: float = lng0 + GRID_STEP * 0.5
			var zid: int = 0
			if _topo.is_on_land(cx, cell_mid_lat):
				var ghi: float = G.ghi_kwh_per_m2_day(cell_mid_lat, cx)
				zid = (G.get_zone(ghi)["id"] as int) & 0xFF
			_zone_id_cache[idx] = zid
			if zid != 0:
				var row: int = idx / GRID_COLS
				var col: int = idx % GRID_COLS
				var img_y: int = (GRID_ROWS - 1) - row
				var colr: Color = _zone_color_safe(zid)
				_zone_base_img.set_pixel(col, img_y, Color(colr.r, colr.g, colr.b, 1.0))
			idx += 1
			lng0 += GRID_STEP
		lat0 += GRID_STEP
	_on_land_built = true

func _ensure_tint_texture() -> void:
	if _zone_base_img == null:
		return
	if _tint_tex != null and _tint_focus == focus_zone_id:
		return
	var img := _zone_base_img.duplicate()
	if focus_zone_id >= 1:
		for row in range(GRID_ROWS):
			for col in range(GRID_COLS):
				var gidx: int = row * GRID_COLS + col
				if gidx >= _zone_id_cache.size():
					break
				var z4: int = int(_zone_id_cache[gidx])
				if z4 == 0 or z4 == focus_zone_id:
					continue
				var px: Color = img.get_pixel(col, (GRID_ROWS - 1) - row)
				px.a = ZONE_UNFOCUSED
				img.set_pixel(col, (GRID_ROWS - 1) - row, px)
	_tint_tex = ImageTexture.create_from_image(img)
	_tint_focus = focus_zone_id

func _view_src_rect() -> Rect2:
	var b: Dictionary = _view_bounds()
	var lng_span: float = maxf(b["lng_max"] - b["lng_min"], 0.001)
	var lat_span: float = maxf(b["lat_max"] - b["lat_min"], 0.001)
	var x0: float = (b["lng_min"] + 180.0) / 360.0 * float(GRID_COLS)
	var y0: float = (90.0 - b["lat_max"]) / 180.0 * float(GRID_ROWS)
	var w: float = lng_span / 360.0 * float(GRID_COLS)
	var h: float = lat_span / 180.0 * float(GRID_ROWS)
	x0 = clampf(x0, 0.0, float(GRID_COLS - 1))
	y0 = clampf(y0, 0.0, float(GRID_ROWS - 1))
	w = clampf(w, 1.0, float(GRID_COLS) - x0)
	h = clampf(h, 1.0, float(GRID_ROWS) - y0)
	return Rect2(x0, y0, w, h)

func equirect_project(lng: float, lat: float) -> Vector2:
	var b: Dictionary = _view_bounds()
	var lng_span: float = b["lng_max"] - b["lng_min"]
	var lat_span: float = b["lat_max"] - b["lat_min"]
	if lng_span <= 0.001 or lat_span <= 0.001:
		return Vector2(-9999.0, -9999.0)
	var x: float = (lng - b["lng_min"]) / lng_span * _css_w
	var y: float = (b["lat_max"] - lat) / lat_span * _css_h
	return Vector2(x, y)

func equirect_invert(p: Vector2) -> Vector2:
	var b: Dictionary = _view_bounds()
	var lng_span: float = b["lng_max"] - b["lng_min"]
	var lat_span: float = b["lat_max"] - b["lat_min"]
	var lng: float = b["lng_min"] + p.x / maxf(_css_w, 1.0) * lng_span
	var lat: float = b["lat_max"] - p.y / maxf(_css_h, 1.0) * lat_span
	return Vector2(lng, clampf(lat, -90.0, 90.0))

func _geo_visible(lng: float, lat: float, margin_deg: float = 0.0) -> bool:
	var b: Dictionary = _view_bounds()
	return lng >= b["lng_min"] - margin_deg and lng <= b["lng_max"] + margin_deg \
		and lat >= b["lat_min"] - margin_deg and lat <= b["lat_max"] + margin_deg

func _cell_visible(lns: float, lats: float, step: float) -> bool:
	var b: Dictionary = _view_bounds()
	return lns + step >= b["lng_min"] and lns <= b["lng_max"] \
		and lats + step >= b["lat_min"] and lats <= b["lat_max"]

func _zone_color_safe(zid: int) -> Color:
	if G and G.get_zones().size() > 0:
		for z in G.get_zones():
			if int(z["id"]) == zid:
				return (z["color"] as Color)
	for z2 in ZONES_FALL:
		if int(z2["id"]) == zid:
			return (z2["color"] as Color)
	return Color(0.5, 0.5, 0.5)

func _zone_alpha(zid: int, base: float, kml: bool) -> float:
	var b: float = ZONE_KML_ALPHA if kml else base
	if focus_zone_id < 0:
		return b
	if zid == focus_zone_id:
		return b
	return b * ZONE_UNFOCUSED

func _zoom_at_point(factor: float, screen: Vector2) -> void:
	_css_w = maxf(4.0, size.x)
	_css_h = maxf(4.0, size.y)
	var geo: Vector2 = equirect_invert(screen)
	var new_zoom: float = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if new_zoom <= MIN_ZOOM + 0.001:
		reset_view()
		return
	_zoom = new_zoom
	var half := _view_half_extents()
	_view_lng = geo.x + half.x - (screen.x / maxf(_css_w, 1.0)) * half.x * 2.0
	_view_lat = geo.y - half.y + (screen.y / maxf(_css_h, 1.0)) * half.y * 2.0
	_clamp_view()
	queue_redraw()

func _gui_input(e: InputEvent) -> void:
	_css_w = maxf(4.0, size.x)
	_css_h = maxf(4.0, size.y)
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at_point(ZOOM_WHEEL, mb.position)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at_point(1.0 / ZOOM_WHEEL, mb.position)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_panning = true
				_pan_mouse_start = mb.position
				_pan_view_start = Vector2(_view_lng, _view_lat)
				mouse_default_cursor_shape = Control.CURSOR_MOVE
			else:
				_panning = false
				mouse_default_cursor_shape = Control.CURSOR_CROSS
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _zoom > MIN_ZOOM + 0.001 and mb.double_click:
				reset_view()
				accept_event()
				return
			var inv: Vector2 = equirect_invert(mb.position)
			accept_event()
			location_selected.emit(inv.y, inv.x)
			_selected_geo = inv
			queue_redraw()
			return
	if e is InputEventMouseMotion and _panning:
		var mm := e as InputEventMouseMotion
		var half := _view_half_extents()
		var dx: float = mm.position.x - _pan_mouse_start.x
		var dy: float = mm.position.y - _pan_mouse_start.y
		_view_lng = _pan_view_start.x - dx / maxf(_css_w, 1.0) * half.x * 2.0
		_view_lat = _pan_view_start.y + dy / maxf(_css_h, 1.0) * half.y * 2.0
		_clamp_view()
		queue_redraw()
		accept_event()

func _draw() -> void:
	_css_w = maxf(4.0, size.x)
	_css_h = maxf(4.0, size.y)
	draw_rect(Rect2(0, 0, _css_w, _css_h), OCEAN_COLOR)
	if G == null and not Engine.is_editor_hint():
		G = get_node_or_null("/root/GhiService") as GhiService
	if G == null or not _on_land_built:
		draw_string(ThemeDB.fallback_font, Vector2(8, 20), "Initializing map data…", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.55, 0.6))
		return
	var kml_mode: bool = (not kml_text.is_empty() and not kml_placemarks.is_empty())
	if kml_mode:
		_draw_kml_layers()
	else:
		_ensure_tint_texture()
		if _tint_tex != null:
			draw_texture_rect_region(_tint_tex, Rect2(0.0, 0.0, _css_w, _css_h), _view_src_rect())
		if focus_zone_id >= 0:
			_draw_focus_zone_outlines()
	_draw_coast_outlines()
	if is_finite(_selected_geo.x) and is_finite(_selected_geo.y):
		if _geo_visible(_selected_geo.x, _selected_geo.y, 2.0):
			_draw_marker(_selected_geo.y, _selected_geo.x)
	var cl: String = _coord_label()
	if not cl.is_empty():
		var fs: int = 10
		var sz: Vector2 = ThemeDB.fallback_font.get_string_size(cl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var pad: float = 6.0
		var bx: float = _css_w - sz.x - pad * 2.0 - 8.0
		var by: float = 8.0
		draw_rect(Rect2(bx, by, sz.x + pad * 2.0, fs + 8.0), Color(0.06, 0.1, 0.14, 0.9))
		draw_string(ThemeDB.fallback_font, Vector2(bx + pad, by + fs + 1.0), cl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.99, 0.66, 0.15))
	if _zoom > MIN_ZOOM + 0.001:
		var hint := "Scroll zoom · Right-drag pan · Double-click reset"
		draw_string(ThemeDB.fallback_font, Vector2(8, _css_h - 8), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.45, 0.5, 0.58))

func _coord_label() -> String:
	if not (is_finite(_selected_geo.x) and is_finite(_selected_geo.y)):
		return ""
	var la: float = _selected_geo.y
	var lo: float = _selected_geo.x
	var ns: String = "N" if la >= 0.0 else "S"
	var ew: String = "E" if lo >= 0.0 else "W"
	return "%.4f°%s, %.4f°%s" % [absf(la), ns, absf(lo), ew]

func _draw_focus_zone_outlines() -> void:
	if _zone_id_cache.is_empty() or focus_zone_id < 0:
		return
	var step: float = GRID_STEP
	for row in range(GRID_ROWS):
		var lats: float = -90.0 + float(row) * step
		var lats_n: float = lats + step
		for col in range(GRID_COLS):
			var gidx: int = row * GRID_COLS + col
			if gidx >= _zone_id_cache.size():
				break
			if int(_zone_id_cache[gidx]) != focus_zone_id:
				continue
			var lns: float = -180.0 + float(col) * step
			if not _cell_visible(lns, lats, step):
				continue
			var p0: Vector2 = equirect_project(lns, lats)
			var p1: Vector2 = equirect_project(lns + step, lats)
			var p2: Vector2 = equirect_project(lns + step, lats_n)
			var p3: Vector2 = equirect_project(lns, lats_n)
			if p0.x < -5000.0:
				continue
			var poly2 := PackedVector2Array([p0, p1, p2, p3])
			for t in range(poly2.size()):
				var a: Vector2 = poly2[t]
				var b: Vector2 = poly2[(t + 1) % poly2.size()]
				draw_line(a, b, Color(0.99, 0.76, 0.18, 0.55), 1.0, true)

func _draw_kml_layers() -> void:
	for m in kml_placemarks:
		var zid2: int = int(m.get("zone_id", 1))
		var c: Color = _zone_color_safe(zid2)
		var alpha: float = _zone_alpha(zid2, ZONE_KML_ALPHA, true)
		var coords: Variant = m.get("coordinates", PackedVector2Array())
		if not (coords is PackedVector2Array):
			continue
		var pts: PackedVector2Array = coords
		if pts.size() < 3:
			continue
		var scr: PackedVector2Array = PackedVector2Array()
		for p in pts:
			if _geo_visible(p.x, p.y, 1.0):
				scr.append(equirect_project(p.x, p.y))
		if scr.size() < 3:
			continue
		draw_colored_polygon(scr, Color(c.r, c.g, c.b, alpha))
		for t2 in range(scr.size()):
			draw_line(scr[t2], scr[(t2 + 1) % scr.size()], Color(1, 1, 1, 0.25), 0.5, true)
		if focus_zone_id == zid2 and focus_zone_id >= 0:
			for t3 in range(scr.size()):
				draw_line(scr[t3], scr[(t3 + 1) % scr.size()], Color(0.99, 0.85, 0.3, 0.85), 1.25, true)

func _should_skip_coast_segment(lon1: float, lat1: float, lon2: float, lat2: float) -> bool:
	if absf(lon2 - lon1) > 120.0:
		return true
	if maxf(absf(lat1), absf(lat2)) > 78.0:
		return true
	return false

func _draw_coast_outlines() -> void:
	if not _topo.is_loaded():
		return
	for r in _topo.get_outer_rings():
		if r is not PackedVector2Array:
			continue
		var ring2: PackedVector2Array = r
		if ring2.size() < 2:
			continue
		for p in range(ring2.size() - 1):
			var lon1: float = ring2[p].x
			var lat1: float = ring2[p].y
			var lon2: float = ring2[p + 1].x
			var lat2: float = ring2[p + 1].y
			if _should_skip_coast_segment(lon1, lat1, lon2, lat2):
				continue
			if not _geo_visible(lon1, lat1, 5.0) and not _geo_visible(lon2, lat2, 5.0):
				continue
			draw_line(equirect_project(lon1, lat1), equirect_project(lon2, lat2), Color(1, 1, 1, 0.18), 0.6, true)
		if ring2.size() > 2:
			var lon_a: float = ring2[ring2.size() - 1].x
			var lat_a: float = ring2[ring2.size() - 1].y
			var lon_b: float = ring2[0].x
			var lat_b: float = ring2[0].y
			if not _should_skip_coast_segment(lon_a, lat_a, lon_b, lat_b):
				if _geo_visible(lon_a, lat_a, 5.0) or _geo_visible(lon_b, lat_b, 5.0):
					draw_line(equirect_project(lon_a, lat_a), equirect_project(lon_b, lat_b), Color(1, 1, 1, 0.18), 0.6, true)

func _draw_marker(lat2: float, lon2: float) -> void:
	var p0: Vector2 = equirect_project(lon2, lat2)
	if p0.x < -5000.0:
		return
	var r: float = maxf(4.0, 8.0 / sqrt(_zoom))
	draw_circle(p0, r * 2.2, Color(1, 1, 1, 0.2))
	draw_circle(p0, r, Color(0.99, 0.62, 0.1, 1.0))
	draw_arc(p0, r, 0, TAU, 24, Color(1, 1, 1, 0.9), 1.5, true)

class_name GraphSiteLayout
extends RefCounted

## Physical site-plan helpers: meters ↔ graph/SoI disc, footprints, elevation.
## Freeform graph x/y stay untouched; site placement uses site_x_m / site_z_m
## relative to SoiService center (+X east, +Z south).

const SOI_PX_PER_M := 4.0
const ABSTRACT_FOOTPRINT_M := 3.0
const CLEARANCE_M := 0.15
const ROUTE_SAMPLE_M := 5.0
## Minimum pick target for Site Plan / Elevation hit-testing. Draw size always
## matches physical metres × SOI_PX_PER_M × zoom (no floor) so nodes grow when
## zooming in and shrink with the map when zooming out.
const MIN_SITE_HIT_PX := 28.0
## @deprecated Alias — prefer MIN_SITE_HIT_PX (kept for call sites still updating).
const MIN_SITE_NODE_PX := MIN_SITE_HIT_PX

## View modes shared with GraphCanvas / SystemGraphView.
const VIEW_FREEFORM := "freeform"
const VIEW_SITE := "site"
const VIEW_ELEVATION := "elevation"


static func has_site_coords(item: Dictionary) -> bool:
	return item.has("site_x_m") and item.has("site_z_m") \
			and typeof(item.get("site_x_m")) != TYPE_NIL \
			and typeof(item.get("site_z_m")) != TYPE_NIL


static func site_xz(item: Dictionary) -> Vector2:
	return Vector2(float(item.get("site_x_m", 0.0)), float(item.get("site_z_m", 0.0)))


static func clamp_to_soi(xz: Vector2, radius_m: float) -> Vector2:
	var r := maxf(radius_m, 1.0)
	if xz.length_squared() <= r * r:
		return xz
	return xz.normalized() * r


static func px_per_m(zoom: float) -> float:
	return SOI_PX_PER_M * maxf(zoom, 0.001)


## Typical crystalline module footprint (m) used when array packs lack tags.
const PANEL_MODULE_M := Vector2(1.7, 1.0)


## Physical footprint width×depth in metres (plan view).
static func physical_footprint_m(item: Dictionary) -> Vector2:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if float(specs.get("footprint_w_m", 0.0)) > 0.0 and float(specs.get("footprint_d_m", 0.0)) > 0.0:
		return Vector2(
			maxf(float(specs.get("footprint_w_m", ABSTRACT_FOOTPRINT_M)), 0.5),
			maxf(float(specs.get("footprint_d_m", ABSTRACT_FOOTPRINT_M)), 0.5))
	var model_id := str(specs.get("model_id", ""))
	if not model_id.is_empty():
		var metrics: Dictionary = ModelCatalog.mesh_metrics(model_id)
		if not metrics.is_empty():
			var ws := ModelCatalog.resolved_scale(model_id, 1.0)
			return Vector2(
				maxf(float(metrics.get("width", ABSTRACT_FOOTPRINT_M)) * ws, 0.5),
				maxf(float(metrics.get("depth", ABSTRACT_FOOTPRINT_M)) * ws, 0.5))
	var itype := str(item.get("type", ""))
	match itype:
		"panel":
			# ~0.5 m²/100 W rule-of-thumb; square-ish module footprint.
			var wmp := float(specs.get("wmp", 220.0))
			var area := maxf(wmp, 50.0) * 0.005
			var side := sqrt(area)
			return Vector2(side, side)
		"battery", "smartbattery":
			return Vector2(0.6, 0.4)
		"resource":
			var cap := float(specs.get("capacity_qty", 100.0))
			var side := clampf(sqrt(maxf(cap, 10.0)) * 0.08, 0.8, 6.0)
			return Vector2(side, side)
		"wind":
			var d := float(specs.get("rotor_diameter_m", 2.1))
			return Vector2(maxf(d * 0.35, 1.0), maxf(d * 0.35, 1.0))
		"hydro":
			return Vector2(1.5, 1.2)
		"catchment":
			var area_m2 := float(specs.get("area_m2", 50.0))
			var side := sqrt(maxf(area_m2, 4.0))
			return Vector2(side, side)
		"compound":
			return _compound_footprint_m(specs)
		"controller", "pbi", "import", "export":
			return Vector2(ABSTRACT_FOOTPRINT_M, ABSTRACT_FOOTPRINT_M)
		_:
			return Vector2(ABSTRACT_FOOTPRINT_M, ABSTRACT_FOOTPRINT_M)


static func _compound_footprint_m(specs: Dictionary) -> Vector2:
	var kind := str(specs.get("compound_kind", ""))
	if kind == "array":
		var grid: Vector2i = GraphArrayLayout.grid_dims(specs)
		var cols := maxi(grid.x, 1)
		var rows := maxi(grid.y, 1)
		# Pack modules on a physical grid (series × parallel).
		return Vector2(
			maxf(float(cols) * PANEL_MODULE_M.x, 1.0),
			maxf(float(rows) * PANEL_MODULE_M.y, 1.0))
	if kind == "battery_bank":
		var n := maxi(1, int(specs.get("child_count", specs.get("battery_count", 4))))
		var cols := mini(n, 4)
		var rows := int(ceil(float(n) / float(cols)))
		return Vector2(maxf(float(cols) * 0.6, 1.0), maxf(float(rows) * 0.4, 0.8))
	return Vector2(ABSTRACT_FOOTPRINT_M, ABSTRACT_FOOTPRINT_M)


static func is_abstract_type(itype: String) -> bool:
	return itype in ["pbi", "controller", "compound", "combiner", "solarcombiner",
		"breaker", "acbreaker", "shelly4pm"]


## True when Site Plan should draw a circle (not a footprint rectangle).
static func uses_circular_plan_chip(item: Dictionary) -> bool:
	var itype := str(item.get("type", ""))
	if is_circular_node(itype):
		return true
	if itype != "compound":
		return is_abstract_type(itype)
	var kind := str((item.get("specs", {}) as Dictionary).get("compound_kind", ""))
	# Arrays / battery banks are physical packs — rectangular footprints.
	return kind != "array" and kind != "battery_bank"


## Circular plan symbols (hub tanks / PBI) — use right-edge resize, not BR corner.
static func is_circular_node(itype: String) -> bool:
	return itype in ["pbi", "resource", "catchment"]


## True map-scaled screen size (physical metres × px/m). Grows with zoom-in.
static func site_item_screen_size(item: Dictionary, zoom: float) -> Vector2:
	var raw := physical_footprint_m(item) * px_per_m(zoom)
	# Sub-pixel floor only — never inflate to a UI chip size (that made nodes
	# look larger when zooming out relative to the SoI / terrain).
	return Vector2(maxf(raw.x, 0.5), maxf(raw.y, 0.5))


## Hit-test size: at least MIN_SITE_HIT_PX so tiny footprints stay pickable.
static func site_item_hit_size(item: Dictionary, zoom: float) -> Vector2:
	var draw_sz := site_item_screen_size(item, zoom)
	return Vector2(
		maxf(draw_sz.x, MIN_SITE_HIT_PX),
		maxf(draw_sz.y, MIN_SITE_HIT_PX))


static func site_item_center_screen(item: Dictionary, disc_origin: Vector2, zoom: float) -> Vector2:
	return disc_origin + site_xz(item) * px_per_m(zoom)


## Screen-space top-left of an item in site mode (disc_origin + site×scale − half size).
static func site_item_screen_tl(item: Dictionary, disc_origin: Vector2, zoom: float) -> Vector2:
	var sz := site_item_screen_size(item, zoom)
	return site_item_center_screen(item, disc_origin, zoom) - sz * 0.5


static func site_item_hit_rect(item: Dictionary, disc_origin: Vector2, zoom: float) -> Rect2:
	var c := site_item_center_screen(item, disc_origin, zoom)
	var sz := site_item_hit_size(item, zoom)
	return Rect2(c - sz * 0.5, sz)


## Clamp footprint meters to a sensible SoI-relative range.
static func clamp_footprint_m(fp: Vector2) -> Vector2:
	return Vector2(
		clampf(fp.x, 0.5, 200.0),
		clampf(fp.y, 0.5, 200.0))


## Screen position → site meters (relative to SoI center).
static func screen_to_site_m(screen_pos: Vector2, disc_origin: Vector2, zoom: float) -> Vector2:
	var s := px_per_m(zoom)
	return (screen_pos - disc_origin) / s


## Seed site coords from freeform x/y into the SoI disc (bounding-box fit).
static func seed_site_from_freeform(items: Array, radius_m: float) -> int:
	var placed := 0
	var min_v := Vector2(INF, INF)
	var max_v := Vector2(-INF, -INF)
	var candidates: Array = []
	for item_v in items:
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v
		if has_site_coords(item):
			continue
		var p := Vector2(float(item.get("x", 0.0)), float(item.get("y", 0.0)))
		candidates.append(item)
		min_v = min_v.min(p)
		max_v = max_v.max(p)
	if candidates.is_empty():
		return 0
	var span := max_v - min_v
	var target := radius_m * 1.4
	var scale := 1.0
	if span.x > 1.0 or span.y > 1.0:
		scale = minf(target / maxf(span.x, 1.0), target / maxf(span.y, 1.0))
	var mid := (min_v + max_v) * 0.5
	for item2: Dictionary in candidates:
		var p2 := Vector2(float(item2.get("x", 0.0)), float(item2.get("y", 0.0)))
		var xz := clamp_to_soi((p2 - mid) * scale, radius_m * 0.92)
		item2["site_x_m"] = xz.x
		item2["site_z_m"] = xz.y
		placed += 1
	return placed


## World XZ from site meters + SoI center.
static func site_to_world_xz(site: Vector2, soi_center: Vector3) -> Vector2:
	return Vector2(soi_center.x + site.x, soi_center.z + site.y)


static func world_xz_to_site(world_xz: Vector2, soi_center: Vector3) -> Vector2:
	return Vector2(world_xz.x - soi_center.x, world_xz.y - soi_center.z)


## Project site point onto a section heading (radians, 0 = +X / east).
## Returns Vector2(along_m, cross_m).
static func project_onto_section(site: Vector2, heading_rad: float) -> Vector2:
	var along_dir := Vector2(cos(heading_rad), sin(heading_rad))
	var cross_dir := Vector2(-sin(heading_rad), cos(heading_rad))
	return Vector2(site.dot(along_dir), site.dot(cross_dir))


static func section_to_site(along_m: float, cross_m: float, heading_rad: float) -> Vector2:
	var along_dir := Vector2(cos(heading_rad), sin(heading_rad))
	var cross_dir := Vector2(-sin(heading_rad), cos(heading_rad))
	return along_dir * along_m + cross_dir * cross_m


## Default conduit type from connection polarity / resource_type.
static func default_conduit_type(conn: Dictionary) -> String:
	return ConduitKinds.derive_type_for_connection(conn)

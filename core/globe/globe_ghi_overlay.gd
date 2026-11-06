class_name GlobeGhiOverlay
extends RefCounted

## The solar-energy-zone layer for the globe: the 2D picker's own numbers
## (GhiService, NASA POWER 2001-2020 mean all-sky GHI, 1°, bilinear) on land
## (TopojsonLoader, Natural Earth 110m), as a 360 x 180 equirect texture,
## R = GHI / MAX_GHI, G = land. The GPU's linear filter makes it read smooth.
## Built once on a worker thread and cached as a PNG.

const MAX_GHI := 8.0
const W := 360
const H := 180
const CACHE := "user://globe_cache/ghi_overlay_v4.png"
const GHI := preload("res://scenes/ui/location_picker/ghi_service.gd")


## Band edges and colours, straight from GHI.ZONES.
static func steps() -> Array:
	var out: Array = []
	for z in GHI.ZONES:
		var hi := float(z.range_hi)
		if not is_inf(hi):
			out.append(hi)
	return out


static func colors() -> Array:
	var out: Array = []
	for z in GHI.ZONES:
		out.append(z.color)
	return out


static func load_cached() -> Texture2D:
	if not FileAccess.file_exists(CACHE):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(CACHE))
	if img == null or img.is_empty() or img.get_width() != W:
		return null
	return ImageTexture.create_from_image(img)


## Pure: the image from a GHI sampler and a land test (both Callables taking
## (lat, lon) / (lon, lat) as GhiService / TopojsonLoader do). Row 0 = 90° N.
static func build_image(ghi_at: Callable, on_land: Callable) -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	for y in H:
		var lat := 90.0 - (float(y) + 0.5) * 180.0 / float(H)
		for x in W:
			var lon := -180.0 + (float(x) + 0.5) * 360.0 / float(W)
			# Majority of three latitudes: TopojsonLoader's even-odd test reads a
			# whole row as land where a polygon crossing the antimeridian has an
			# edge at exactly that latitude (Fiji: the -16.5 row was land all
			# the way round, a red line across the oceans).
			var votes := 0
			for dl in [-0.3, 0.0, 0.3]:
				if bool(on_land.call(lon, lat + dl)):
					votes += 1
			var land := votes >= 2
			var g := float(ghi_at.call(lat, lon))
			img.set_pixel(x, y, Color(clampf(g / MAX_GHI, 0.0, 1.0), 1.0 if land else 0.0, 0.0, 1.0))
	return img


## A point-in-land test over outer rings that copes with the antimeridian.
## In countries-110m two small islands cross 180° (Fiji at -16.5°, Wrangel at
## 71°): read raw, their bounding box covers every longitude and the even-odd
## test marked a whole band of latitudes as land all the way round the world.
## A ring wide in longitude (> 180°) but short in latitude (< 10°) is such an
## island: it is unwrapped onto 0..360 and tested at lon and lon + 360. The
## big rings that also span every longitude (Antarctica, and one 1324-point
## stitched outline from -35° to 78°) are right as they are and stay raw.
static func land_test(rings: Array) -> Callable:
	var polys: Array[PackedVector2Array] = []
	var boxes: Array[Rect2] = []
	var wrapped: Array[bool] = []
	for r in rings:
		var ring: PackedVector2Array = r
		if ring.size() < 3:
			continue
		var bb := Rect2(ring[0], Vector2.ZERO)
		for p in ring:
			bb = bb.expand(p)
		var wrap := bb.size.x > 180.0 and bb.size.y < 10.0
		if wrap:
			var u := PackedVector2Array()
			for p in ring:
				u.append(Vector2(p.x + 360.0 if p.x < 0.0 else p.x, p.y))
			ring = u
			bb = Rect2(ring[0], Vector2.ZERO)
			for p in ring:
				bb = bb.expand(p)
		polys.append(ring)
		boxes.append(bb.grow(0.05))
		wrapped.append(wrap)
	return func(lon: float, lat: float) -> bool:
		for i in polys.size():
			var b: Rect2 = boxes[i]
			if lat < b.position.y or lat > b.end.y:
				continue
			for x in ([lon, lon + 360.0] if wrapped[i] else [lon]):
				if x < b.position.x or x > b.end.x:
					continue
				if Geometry2D.is_point_in_polygon(Vector2(x, lat), polys[i]):
					return true
		return false


## Builds (or loads) the texture and calls done(tex) on the main thread.
## Returns the WorkerThreadPool task id (-1 when it came from the cache); the
## caller must wait on it before it is freed (an un-waited task crashes quit).
static func build_async(ghi: Node, done: Callable) -> int:
	var cached := load_cached()
	if cached != null:
		done.call(cached)
		return -1
	var topo := TopojsonLoader.new()
	var on_land: Callable
	if topo.load_from_path():
		on_land = land_test(topo.get_outer_rings())
	else:
		push_warning("GlobeGhiOverlay: no country outlines; the layer covers sea too")
		on_land = func(_lon: float, _lat: float) -> bool: return true
	var ghi_at := func(lat: float, lon: float) -> float:
		return float(ghi.call("ghi_kwh_per_m2_day", lat, lon))
	return WorkerThreadPool.add_task(func() -> void:
		var img := build_image(ghi_at, on_land)
		var finish := func() -> void:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE.get_base_dir()))
			img.save_png(CACHE)
			done.call(ImageTexture.create_from_image(img))
		finish.call_deferred())

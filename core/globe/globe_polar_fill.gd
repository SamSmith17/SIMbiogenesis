class_name GlobePolarFill
extends Node

## The caps past Web Mercator's ±85.05°. A polar-stereographic image per pole:
## NASA GIBS MODIS Terra true colour in EPSG:4326 (those tiles include the
## poles; the globe's everyday imagery does not), and a generated ice picture
## when that request fails so the Arctic is never a flat grey disc.
##
## UV: the pole is the centre of the texture, longitude 0 is up, and the
## circle of radius 0.5 is the Mercator edge. North and south share the
## orientation (lon 0 up); the latitude sign is the caller's.

signal cap_ready(north: bool, tex: Texture2D, live: bool)

const SIZE := 512
const ZOOM := 3
const CREDIT := "Poles: NASA MODIS Terra (GIBS)"
const _URL := "https://gibs.earthdata.nasa.gov/wmts/epsg4326/best/MODIS_Terra_CorrectedReflectance_TrueColor/default/%s/250m/%d/%d/%d.jpg"

var _http: Array[HTTPRequest] = []
var _free: Array[HTTPRequest] = []
var _job := {}          # date -> {north: {col: Image}, south: {...}, pending: int}
var _want := ""


static func uv_of(lat_deg: float, lon_deg: float) -> Vector2:
	var span := 90.0 - GlobeMath.MERCATOR_MAX_LAT
	var t := clampf((90.0 - absf(lat_deg)) / span, 0.0, 1.0)
	var rad := t * 0.5
	var lon := deg_to_rad(lon_deg)
	return Vector2(0.5 + rad * sin(lon), 0.5 - rad * cos(lon))


## [lat, lon] of a texture pixel. `u`/`v` are 0..1, v down.
static func latlon_of(north: bool, u: float, v: float) -> PackedFloat64Array:
	var dx := u - 0.5
	var dy := 0.5 - v
	var rad := clampf(sqrt(dx * dx + dy * dy) / 0.5, 0.0, 1.0)
	var span := 90.0 - GlobeMath.MERCATOR_MAX_LAT
	var lat := 90.0 - rad * span
	if not north:
		lat = -lat
	var lon := rad_to_deg(atan2(dx, dy)) if rad > 1e-6 else 0.0
	return PackedFloat64Array([lat, lon])


## Ice (north: sea ice with a few leads; south: the ice sheet) so a failed
## fetch still reads as a pole rather than the grey placeholder.
static func fallback_image(north: bool) -> Image:
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var ll := latlon_of(north, (float(x) + 0.5) / float(n), (float(y) + 0.5) / float(n))
			var lat := ll[0]
			var lon := ll[1]
			var lead := 0.5 + 0.5 * sin(lon * 0.11 + lat * 0.4) * sin(lon * 0.37 - lat * 0.2)
			lead = smoothstep(0.72, 0.86, lead)
			var grain := 0.04 * sin(lon * 0.7 + lat) * sin(lon * 1.3 - lat * 0.5)
			var c := Color(0.78 + grain, 0.82 + grain, 0.78)
			if north:
				c = Color(0.72, 0.80, 0.84).lerp(Color(0.10, 0.22, 0.34), lead * 0.75)
			img.set_pixel(x, y, c)
	return img


static func fallback_texture(north: bool) -> ImageTexture:
	return ImageTexture.create_from_image(fallback_image(north))


func _ready() -> void:
	for i in 4:
		var h := HTTPRequest.new()
		h.timeout = 20.0
		h.use_threads = true
		add_child(h)
		h.request_completed.connect(_on_done.bind(h))
		_http.append(h)
		_free.append(h)


## Ask for both caps on `date` (YYYY-MM-DD). A cached composite is used as-is.
## No network while GlobeTileFetcher.offline_for_test is set.
func request_date(date: String) -> void:
	if date == _want or date.is_empty():
		return
	_want = date
	_job.clear()
	if GlobeTileFetcher.offline_for_test:
		return
	for north in [true, false]:
		var cached := _cache_path(date, north)
		if FileAccess.file_exists(cached):
			var img := Image.new()
			if img.load(cached) == OK:
				cap_ready.emit(north, ImageTexture.create_from_image(img), true)
				continue
		_start(date, north)


func _cache_path(date: String, north: bool) -> String:
	return "user://globe_cache/polar/%s_%s.png" % [date, "n" if north else "s"]


func _cols() -> int:
	return 2 * (1 << ZOOM)


func _rows() -> int:
	return 1 << ZOOM


func _start(date: String, north: bool) -> void:
	var side := "n" if north else "s"
	var key := "%s|%s" % [date, side]
	var tried: Array = []
	tried.resize(_cols())
	tried.fill(false)
	_job[key] = {"date": date, "north": north, "images": [], "tried": tried, "got": 0, "fail": 0}
	(_job[key].images as Array).resize(_cols())
	_pump(key)


func _pump(key: String) -> void:
	if not _job.has(key) or _free.is_empty():
		return
	var job: Dictionary = _job[key]
	var cols := _cols()
	while not _free.is_empty():
		var col := -1
		for c in cols:
			if (job.tried as Array)[c] != true:
				col = c
				break
		if col < 0:
			return
		(job.tried as Array)[col] = true
		var h: HTTPRequest = _free.pop_back()
		var row: int = 0 if job.north == true else _rows() - 1
		var url := _URL % [str(job.date), ZOOM, row, col]
		h.set_meta("polar_key", key)
		h.set_meta("polar_col", col)
		if h.request(url) != OK:
			_free.append(h)
			job.fail = int(job.fail) + 1
			_finish_if_done(key)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, h: HTTPRequest) -> void:
	_free.append(h)
	var key := str(h.get_meta("polar_key", ""))
	var col := int(h.get_meta("polar_col", -1))
	if not _job.has(key):
		return
	var job: Dictionary = _job[key]
	var img := Image.new()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200 and img.load_jpg_from_buffer(body) == OK
	if ok:
		(job.images as Array)[col] = img
		job.got = int(job.got) + 1
	else:
		job.fail = int(job.fail) + 1
	if int(job.got) + int(job.fail) < _cols():
		_pump(key)
		return
	_finish_if_done(key)


func _finish_if_done(key: String) -> void:
	if not _job.has(key):
		return
	var job: Dictionary = _job[key]
	if int(job.got) + int(job.fail) < _cols():
		return
	var date := str(job.date)
	var north: bool = job.north == true
	_job.erase(key)
	if date != _want or int(job.got) < _cols():
		return
	var img := _composite(north, job.images)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://globe_cache/polar"))
	img.save_png(_cache_path(date, north))
	cap_ready.emit(north, ImageTexture.create_from_image(img), true)


func _composite(north: bool, images: Array) -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var cols := images.size()
	var rows := _rows()
	var row := 0 if north else rows - 1
	var xspan := 360.0 / float(cols)
	var lat_top := 90.0 - float(row) * (180.0 / float(rows))
	var lat_span := 180.0 / float(rows)
	for y in SIZE:
		for x in SIZE:
			var ll := latlon_of(north, (float(x) + 0.5) / float(SIZE), (float(y) + 0.5) / float(SIZE))
			var lon := float(ll[1])
			var lat := float(ll[0])
			var col := clampi(int(floor((lon + 180.0) / xspan)), 0, cols - 1)
			var tile: Image = images[col]
			if tile == null:
				continue
			var lon0 := -180.0 + float(col) * xspan
			var tx := clampf((lon - lon0) / xspan, 0.0, 0.999)
			var ty := clampf((lat_top - lat) / lat_span, 0.0, 0.999)
			var px := clampi(int(tx * float(tile.get_width())), 0, tile.get_width() - 1)
			var py := clampi(int(ty * float(tile.get_height())), 0, tile.get_height() - 1)
			img.set_pixel(x, y, tile.get_pixel(px, py))
	return img

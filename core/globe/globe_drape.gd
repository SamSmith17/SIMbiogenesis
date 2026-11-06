class_name GlobeDrape
extends RefCounted

## A world's own terrain photos on the globe (Globe mode Phase 6, pure).
##
## ImageryService caches every drape a world loaded as
## user://terrain_cache/imagery/img_<v1|v3>_<lat>_<lon>_<half m>_z<z>[_<sources>].png,
## a Web Mercator mosaic cropped to GeoMath.bbox_for(lat, lon, half): x is
## linear in longitude, y in Mercator y. The globe draws up to two of them
## (a wide one, a few km, and the finest site patch) over its own tiles when
## the camera comes down near that world, so zooming in lands on the same
## photo the world is built on.
##
## Precision: the shader cannot take a Mercator DIFFERENCE from absolute
## latitudes in float32 (the 2 m blocks CLAUDE.md warns about). It works with
## d = lat - lat_c instead and the series S(d) = ∫ sec from lat_c, to d³:
##   S(d) = sec c · d + sec c tan c · d²/2 + (sec c tan² c + sec³ c) · d³/6
## (k1, k2, k3 below); the box's edges in S are computed here exactly.

const CACHE_DIR := "user://terrain_cache/imagery"
## A drape this wide or narrower is the "fine" site patch.
const FINE_MAX_HALF_M := 700.0
## Wider than this is a base drape the globe's own tiles already match.
const WIDE_MAX_HALF_M := 5000.0


## {ver, lat, lon, half, z, src} from a cache file name, {} if it is not one.
static func parse_name(fname: String) -> Dictionary:
	var f := fname.get_file()
	if not f.ends_with(".png") or not f.begins_with("img_v"):
		return {}
	var parts := f.trim_suffix(".png").split("_")
	if parts.size() < 6:
		return {}
	var zs := parts[5]
	if not zs.begins_with("z") or not zs.substr(1).is_valid_int():
		return {}
	if not parts[2].is_valid_float() or not parts[3].is_valid_float() or not parts[4].is_valid_int():
		return {}
	var src := "_".join(parts.slice(6)) if parts.size() > 6 else ""
	return {"ver": parts[1], "lat_s": parts[2], "lon_s": parts[3], "lat": parts[2].to_float(),
		"lon": parts[3].to_float(), "half": parts[4].to_float(), "z": zs.substr(1).to_int(),
		"src": src, "file": f}


## The cached drapes of a site (lat / lon matched at the cache's 4 decimals).
static func drapes_for(lat: float, lon: float, files: PackedStringArray) -> Array:
	var la := "%.4f" % lat
	var lo := "%.4f" % lon
	var out: Array = []
	for f in files:
		var d := parse_name(f)
		if d.is_empty() or str(d.lat_s) != la or str(d.lon_s) != lo:
			continue
		if str(d.src).begins_with("wayback"):
			continue   # a photo of another year
		out.append(d)
	return out


## Ground metres per pixel of a cached drape (Web Mercator at that zoom).
static func m_per_px(d: Dictionary) -> float:
	return 156543.03392 * cos(deg_to_rad(float(d.lat))) / float(1 << int(d.z))


## {wide, fine}: the sharpest drape in each size class ({} when none). Ties
## go to a regional / chained source (it is a sharper photo by design), then
## to the v3 layout.
static func pick(cands: Array) -> Dictionary:
	var best := {"wide": {}, "fine": {}}
	for d in cands:
		var half := float(d.half)
		var cls := ""
		if half <= FINE_MAX_HALF_M:
			cls = "fine"
		elif half <= WIDE_MAX_HALF_M:
			cls = "wide"
		else:
			continue
		var cur: Dictionary = best[cls]
		if cur.is_empty() or _better(d, cur):
			best[cls] = d
	return best


static func _better(a: Dictionary, b: Dictionary) -> bool:
	var ma := m_per_px(a)
	var mb := m_per_px(b)
	if absf(ma - mb) > 1e-3:
		return ma < mb
	var sa := 0 if str(a.src).is_empty() else 1
	var sb := 0 if str(b.src).is_empty() else 1
	if sa != sb:
		return sa > sb
	if str(a.ver) != str(b.ver):
		return str(a.ver) > str(b.ver)
	return float(a.half) > float(b.half)


static func merc_exact(lat_rad: float) -> float:
	return log(tan(PI * 0.25 + lat_rad * 0.5))


## The series coefficients at a centre latitude (radians).
static func series_k(lat_c: float) -> Vector3:
	var sc := 1.0 / cos(lat_c)
	var tc := tan(lat_c)
	return Vector3(sc, sc * tc * 0.5, (sc * tc * tc + sc * sc * sc) / 6.0)


static func series(d: float, k: Vector3) -> float:
	return ((k.z * d + k.y) * d + k.x) * d


## Shader parameters for drape slot `slot` ("d0_" / "d1_"): centre, series,
## box edges (S at north and south, longitude offsets west and east).
static func shader_params(slot: String, d: Dictionary) -> Dictionary:
	var lat := float(d.lat)
	var lon := float(d.lon)
	var bb := GeoMath.bbox_for(lat, lon, float(d.half))
	var lat_c := deg_to_rad(lat)
	var lon_c := deg_to_rad(lon)
	var k := series_k(lat_c)
	var sn := merc_exact(deg_to_rad(float(bb.north))) - merc_exact(lat_c)
	var ss := merc_exact(deg_to_rad(float(bb.south))) - merc_exact(lat_c)
	return {
		slot + "c": Vector2(lat_c, lon_c),
		slot + "k": k,
		slot + "box": Vector4(sn, ss, deg_to_rad(float(bb.west)) - lon_c, deg_to_rad(float(bb.east)) - lon_c),
	}


## (u, v) of a point in a drape (the shader's arithmetic, in doubles), for
## tests: u east, v south, 0..1 inside.
static func uv_of(params: Dictionary, slot: String, lat: float, lon: float) -> Vector2:
	var c: Vector2 = params[slot + "c"]
	var k: Vector3 = params[slot + "k"]
	var box: Vector4 = params[slot + "box"]
	var d := deg_to_rad(lat) - c.x
	var dl := deg_to_rad(lon) - c.y
	dl -= TAU * roundf(dl / TAU)
	var s := series(d, k)
	return Vector2((dl - box.z) / (box.w - box.z), (box.x - s) / (box.x - box.y))

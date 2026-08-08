class_name GeoMath
extends RefCounted

## Pure geographic / map-projection helpers for the location→world terrain
## pipeline (ROADMAP Pillar 1). All functions are static and side-effect free so
## they can be unit-tested headless (core/terrain/terrain_selftest.gd).
##
## Conventions:
## - lon/lat are WGS84 degrees (lon −180..180, lat −85.05..85.05 for Web Mercator).
## - XYZ "slippy" tiles use the standard Web Mercator scheme (z = zoom, x grows
##   east, y grows south). Tile (x, y) at zoom z covers a square; (x, y) names its
##   north-west corner.
## - Local terrain is built on a tangent plane in metres centred on the site.

## Mean metres per degree of latitude (spherical approximation). Good to <0.5%
## across the globe — well within DEM noise for a ~30 km tile.
const M_PER_DEG_LAT := 111320.0


## ---------------------------------------------------------------------------
## Hyperbolic helpers (GDScript has no sinh/asinh builtins)
## ---------------------------------------------------------------------------

static func sinh(x: float) -> float:
	return (exp(x) - exp(-x)) * 0.5


static func asinh(x: float) -> float:
	return log(x + sqrt(x * x + 1.0))


## ---------------------------------------------------------------------------
## Tangent-plane metric
## ---------------------------------------------------------------------------

## Metres per degree at the given latitude: x = longitude metres/deg (shrinks
## with cos lat), y = latitude metres/deg (~constant).
static func meters_per_deg(lat_deg: float) -> Vector2:
	var lon_m := M_PER_DEG_LAT * cos(deg_to_rad(lat_deg))
	return Vector2(lon_m, M_PER_DEG_LAT)


## Geographic bounding box for a square of side (2 * half_extent_m) centred on
## (lat, lon). Returns {north, south, east, west} in degrees.
static func bbox_for(lat_deg: float, lon_deg: float, half_extent_m: float) -> Dictionary:
	var mpd := meters_per_deg(lat_deg)
	var dlat := half_extent_m / mpd.y
	var dlon := half_extent_m / maxf(mpd.x, 1.0)
	return {
		"north": lat_deg + dlat,
		"south": lat_deg - dlat,
		"east": lon_deg + dlon,
		"west": lon_deg - dlon,
	}


## Local tangent-plane metres for a WGS84 point relative to a site centre.
## Matches the terrain mesh: +X east, +Z south (north is −Z).
static func lonlat_to_local_m(lat_deg: float, lon_deg: float,
		center_lat_deg: float, center_lon_deg: float) -> Vector2:
	var mpd := meters_per_deg(center_lat_deg)
	var x := (lon_deg - center_lon_deg) * mpd.x
	var z := (center_lat_deg - lat_deg) * mpd.y
	return Vector2(x, z)


## Inverse of lonlat_to_local_m (for tests / debugging).
static func local_m_to_lonlat(x_m: float, z_m: float,
		center_lat_deg: float, center_lon_deg: float) -> Vector2:
	var mpd := meters_per_deg(center_lat_deg)
	var lon := center_lon_deg + x_m / maxf(mpd.x, 1.0)
	var lat := center_lat_deg - z_m / mpd.y
	return Vector2(lon, lat)


## ---------------------------------------------------------------------------
## Web Mercator tile math
## ---------------------------------------------------------------------------

## Fractional tile coordinate (NOT floored) for a lon/lat at zoom z. The integer
## parts are the tile indices; the fractional parts locate the point inside the
## tile — needed for sub-tile UV alignment when draping imagery.
static func lonlat_to_tile_f(lon_deg: float, lat_deg: float, z: int) -> Vector2:
	var n := float(1 << z)
	var x := (lon_deg + 180.0) / 360.0 * n
	var lat_rad := deg_to_rad(clampf(lat_deg, -85.05112878, 85.05112878))
	var y := (1.0 - asinh(tan(lat_rad)) / PI) / 2.0 * n
	return Vector2(x, y)


static func lonlat_to_tile(lon_deg: float, lat_deg: float, z: int) -> Vector2i:
	var f := lonlat_to_tile_f(lon_deg, lat_deg, z)
	return Vector2i(int(floor(f.x)), int(floor(f.y)))


## Lon/lat of a tile's north-west corner. Pass fractional x/y to get any point.
static func tile_to_lonlat(x: float, y: float, z: int) -> Vector2:
	var n := float(1 << z)
	var lon := x / n * 360.0 - 180.0
	var lat_rad := atan(sinh(PI * (1.0 - 2.0 * y / n)))
	return Vector2(lon, rad_to_deg(lat_rad))


## Inclusive tile index range covering a bbox at zoom z:
## {min_x, min_y, max_x, max_y}. (min_y is the northern row since y grows south.)
static func tile_range_for_bbox(bbox: Dictionary, z: int) -> Dictionary:
	var nw := lonlat_to_tile(bbox["west"], bbox["north"], z)
	var se := lonlat_to_tile(bbox["east"], bbox["south"], z)
	var n := (1 << z) - 1
	return {
		"min_x": clampi(mini(nw.x, se.x), 0, n),
		"max_x": clampi(maxi(nw.x, se.x), 0, n),
		"min_y": clampi(mini(nw.y, se.y), 0, n),
		"max_y": clampi(maxi(nw.y, se.y), 0, n),
	}


## ---------------------------------------------------------------------------
## UTM (Transverse Mercator) forward projection
## ---------------------------------------------------------------------------
## USGS 3DEP 1 m lidar DEMs are published in UTM metres, not geographic degrees,
## so an AAIGrid from that source carries eastings/northings in its header and
## must be indexed in projected metres — see
## ElevationService.resample_aaigrid_to_bbox. The SRTM/COP/USGS10m grids
## OpenTopography serves are in degrees, hence the two code paths.
##
## Series form from Snyder, "Map Projections — A Working Manual", USGS
## Professional Paper 1395 (1987): meridional arc eq. 3-21, forward TM eqs.
## 8-9 … 8-11.
##
## We project on the WGS84 ellipsoid while the USGS products are NAD83. The two
## differ by ~1 m horizontally in CONUS — sub-cell for a 1 m DEM and far below
## its own noise — so the datum shift is deliberately not modelled.

const UTM_A := 6378137.0            ## WGS84 semi-major axis (m)
const UTM_E2 := 0.00669437999014    ## WGS84 first eccentricity squared
const UTM_K0 := 0.9996              ## UTM scale factor on the central meridian
const UTM_FALSE_EASTING := 500000.0
const UTM_FALSE_NORTHING_SOUTH := 10000000.0


## UTM zone (1..60) for a longitude. Zones are 6° wide starting at −180°. The
## Norway/Svalbard width exceptions are NOT applied — they only bite over
## Scandinavia and every consumer here is a US 3DEP product.
static func utm_zone_for_lon(lon_deg: float) -> int:
	return clampi(int(floor(fposmod(lon_deg + 180.0, 360.0) / 6.0)) + 1, 1, 60)


## Central meridian of a UTM zone, in degrees.
static func utm_central_meridian(zone: int) -> float:
	return float(clampi(zone, 1, 60) - 1) * 6.0 - 180.0 + 3.0


## Forward UTM projection. Returns {easting, northing, zone} in metres; pass
## `zone` to force one (a bbox straddling a zone edge must project every sample
## into the SAME zone as the grid it indexes, not each into its own).
##
## The components are plain GDScript floats (64-bit). Do NOT round-trip them
## through Vector2: its 32-bit components resolve a ~3,690,000 m northing only
## to ~0.25 m, which would blur a 1 m DEM.
static func lonlat_to_utm(lat_deg: float, lon_deg: float, zone: int = -1) -> Dictionary:
	var z := zone if (zone >= 1 and zone <= 60) else utm_zone_for_lon(lon_deg)
	var lat := deg_to_rad(clampf(lat_deg, -80.0, 84.0))
	var dlon := deg_to_rad(wrapf(lon_deg - utm_central_meridian(z), -180.0, 180.0))
	var sin_lat := sin(lat)
	var cos_lat := cos(lat)
	var tan_lat := tan(lat)
	var ep2 := UTM_E2 / (1.0 - UTM_E2)
	var rn := UTM_A / sqrt(1.0 - UTM_E2 * sin_lat * sin_lat)
	var t := tan_lat * tan_lat
	var c := ep2 * cos_lat * cos_lat
	var a := dlon * cos_lat
	var e4 := UTM_E2 * UTM_E2
	var e6 := e4 * UTM_E2
	# Meridional arc from the equator (Snyder 3-21).
	var m := UTM_A * (
		(1.0 - UTM_E2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0) * lat
		- (3.0 * UTM_E2 / 8.0 + 3.0 * e4 / 32.0 + 45.0 * e6 / 1024.0) * sin(2.0 * lat)
		+ (15.0 * e4 / 256.0 + 45.0 * e6 / 1024.0) * sin(4.0 * lat)
		- (35.0 * e6 / 3072.0) * sin(6.0 * lat))
	var a2 := a * a
	var a3 := a2 * a
	var a4 := a2 * a2
	var a5 := a4 * a
	var a6 := a4 * a2
	var easting := UTM_K0 * rn * (
		a
		+ (1.0 - t + c) * a3 / 6.0
		+ (5.0 - 18.0 * t + t * t + 72.0 * c - 58.0 * ep2) * a5 / 120.0
	) + UTM_FALSE_EASTING
	var northing := UTM_K0 * (m + rn * tan_lat * (
		a2 / 2.0
		+ (5.0 - t + 9.0 * c + 4.0 * c * c) * a4 / 24.0
		+ (61.0 - 58.0 * t + t * t + 600.0 * c - 330.0 * ep2) * a6 / 720.0))
	if lat_deg < 0.0:
		northing += UTM_FALSE_NORTHING_SOUTH
	return {"easting": easting, "northing": northing, "zone": z}


## Choose a zoom so the stitched imagery for `bbox` is roughly `target_px` across
## (256 px per tile). Clamped to [1, max_zoom].
static func pick_zoom(bbox: Dictionary, target_px: int = 2048, max_zoom: int = 17) -> int:
	var width_deg: float = absf(float(bbox["east"]) - float(bbox["west"]))
	if width_deg <= 0.0:
		return max_zoom
	# Tiles spanning the bbox at zoom z ≈ (width/360) * 2^z; pixels = tiles * 256.
	for z in range(max_zoom, 0, -1):
		var tiles_across := width_deg / 360.0 * float(1 << z)
		if tiles_across * 256.0 <= float(target_px):
			return z
	return 1

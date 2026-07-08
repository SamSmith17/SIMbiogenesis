class_name SolarEclipse
extends RefCounted

## Solar-eclipse geometry from sun/moon direction vectors (flat-disc overlap on the
## celestial sphere). Good enough for sky rendering and totality dimming; not a
## substitute for Besselian-element path prediction (±km shadow track).

## Mean geocentric semidiameters (degrees). Real values vary ~±3% with distance.
const SUN_ANGULAR_RADIUS_DEG := 0.2662   # ~31.6′ diameter
const MOON_ANGULAR_RADIUS_DEG := 0.2721  # ~32.7′ at mean distance (can cover sun)

static func moon_to_sun_angular_ratio() -> float:
	return ( MOON_ANGULAR_RADIUS_DEG * 2.0 ) / ( SUN_ANGULAR_RADIUS_DEG * 2.0 )


## Overlap area of two circles with radii r1/r2 (radians) and center separation d
## (radians) on a flat projection — accurate to ~0.01° at eclipse scales.
static func _circle_overlap_area( r1: float, r2: float, d: float ) -> float:
	if d >= r1 + r2:
		return 0.0
	if d <= absf( r1 - r2 ):
		return PI * minf( r1, r2 ) * minf( r1, r2 )
	var r1sq := r1 * r1
	var r2sq := r2 * r2
	var alpha := acos( clampf( ( d * d + r1sq - r2sq ) / ( 2.0 * d * r1 ), -1.0, 1.0 ) )
	var beta := acos( clampf( ( d * d + r2sq - r1sq ) / ( 2.0 * d * r2 ), -1.0, 1.0 ) )
	var under := ( -d + r1 + r2 ) * ( d + r1 - r2 ) * ( d - r1 + r2 ) * ( d + r1 + r2 )
	return r1sq * alpha + r2sq * beta - 0.5 * sqrt( maxf( 0.0, under ) )


## Sample eclipse state from unit direction vectors (scene → body).
static func sample( sun_dir: Vector3, moon_dir: Vector3,
		sun_radius_deg: float = SUN_ANGULAR_RADIUS_DEG,
		moon_radius_deg: float = MOON_ANGULAR_RADIUS_DEG ) -> Dictionary:
	if sun_dir.length_squared() < 1e-8 or moon_dir.length_squared() < 1e-8 :
		return _empty()
	var sep_rad := acos( clampf( sun_dir.normalized().dot( moon_dir.normalized() ), -1.0, 1.0 ) )
	var sep_deg := rad_to_deg( sep_rad )
	var sun_r := deg_to_rad( sun_radius_deg )
	var moon_r := deg_to_rad( moon_radius_deg )
	var sun_area := PI * sun_r * sun_r
	var overlap := _circle_overlap_area( sun_r, moon_r, sep_rad )
	var obsc := clampf( overlap / sun_area, 0.0, 1.0 ) if sun_area > 0.0 else 0.0
	var is_total := moon_radius_deg >= sun_radius_deg \
			and sep_deg < moon_radius_deg - sun_radius_deg + 0.02
	var is_annular := moon_radius_deg < sun_radius_deg \
			and sep_deg < sun_radius_deg - moon_radius_deg + 0.02
	# Deep central eclipse: geometry may stop just shy of analytic totality (~0.05 deg
	# ephemeris slack) — treat high obscuration as totality for lighting.
	var is_near_total := obsc > 0.85 and sep_deg < sun_radius_deg + moon_radius_deg
	var magnitude := 0.0
	if sep_deg < sun_radius_deg + moon_radius_deg :
		magnitude = ( sun_radius_deg + moon_radius_deg - sep_deg ) / ( 2.0 * sun_radius_deg )
	return {
		"obscuration": obsc,
		"magnitude": clampf( magnitude, 0.0, 1.5 ),
		"separation_deg": sep_deg,
		"is_total": is_total or is_near_total,
		"is_annular": is_annular,
		"is_partial": obsc > 0.01 and not is_total and not is_annular and not is_near_total,
	}


static func _empty() -> Dictionary:
	return {
		"obscuration": 0.0,
		"magnitude": 0.0,
		"separation_deg": 180.0,
		"is_total": false,
		"is_annular": false,
		"is_partial": false,
		"jd_utc": 0.0,
		"sun_elevation_deg": -90.0,
	}


## Meeus sun+moon at observer → eclipse state. ~0.05–0.1° — good for sim + peak
## timing; umbra path edges need Besselian elements (±50–100 km uncertainty here).
static func sample_observer( lat_deg: float, lon_deg: float, jd_utc: float ) -> Dictionary :
	var sun_pos : Dictionary = SolarPosition.get_position( lat_deg, lon_deg, jd_utc )
	var moon_pos : Dictionary = LunarPosition.get_position( lat_deg, lon_deg, jd_utc )
	var sun_el : float = float( sun_pos.get( "elevation_deg", -90.0 ) )
	if sun_el < -0.5 :
		var empty := _empty()
		empty[ "jd_utc" ] = jd_utc
		empty[ "sun_elevation_deg" ] = sun_el
		return empty
	var sun_dir : Vector3 = SolarPosition.direction_from_horizon(
		float( sun_pos.azimuth_deg ), sun_el )
	var moon_dir : Vector3 = LunarPosition.direction_from_position( moon_pos )
	var moon_r : float = float( moon_pos.get( "angular_radius_deg", MOON_ANGULAR_RADIUS_DEG ) )
	var result : Dictionary = sample( sun_dir, moon_dir, SUN_ANGULAR_RADIUS_DEG, moon_r )
	result[ "jd_utc" ] = jd_utc
	result[ "sun_elevation_deg" ] = sun_el
	return result


## Refine maximum obscuration near jd_center_utc (coarse scan + golden-section).
## half_window_hours: search ± this many hours. ~80 ephemeris evals — cheap on demand.
static func find_peak_at_observer( lat_deg: float, lon_deg: float, jd_center_utc: float,
		half_window_hours: float = 4.0 ) -> Dictionary :
	var coarse_steps := 48
	var window_days : float = half_window_hours * 2.0 / 24.0
	var jd_start : float = jd_center_utc - half_window_hours / 24.0
	var step : float = window_days / float( coarse_steps )
	var best : Dictionary = sample_observer( lat_deg, lon_deg, jd_center_utc )
	for i in range( coarse_steps + 1 ) :
		var jd : float = jd_start + step * float( i )
		var s : Dictionary = sample_observer( lat_deg, lon_deg, jd )
		if float( s.get( "obscuration", 0.0 ) ) > float( best.get( "obscuration", 0.0 ) ) :
			best = s
	var jd_lo : float = float( best.get( "jd_utc", jd_center_utc ) ) - step
	var jd_hi : float = float( best.get( "jd_utc", jd_center_utc ) ) + step
	for _refine in 14 :
		var jd_a : float = jd_lo + ( jd_hi - jd_lo ) * 0.382
		var jd_b : float = jd_lo + ( jd_hi - jd_lo ) * 0.618
		var sa : Dictionary = sample_observer( lat_deg, lon_deg, jd_a )
		var sb : Dictionary = sample_observer( lat_deg, lon_deg, jd_b )
		if float( sa.get( "obscuration", 0.0 ) ) >= float( sb.get( "obscuration", 0.0 ) ) :
			jd_hi = jd_b
			if float( sa.get( "obscuration", 0.0 ) ) >= float( best.get( "obscuration", 0.0 ) ) :
				best = sa
		else :
			jd_lo = jd_a
			if float( sb.get( "obscuration", 0.0 ) ) >= float( best.get( "obscuration", 0.0 ) ) :
				best = sb
	return best


## Scan a calendar year at observer for days with significant solar eclipse.
## Checks only near-new-moon dates (~13 passes × ~62 evals ≪ 1 ms).
static func scan_year_at_observer( lat_deg: float, lon_deg: float, year: int,
		min_obscuration: float = 0.08 ) -> Array :
	var hits : Array = []
	var synodic : float = 29.530588
	var anchor_jd : float = 2451549.5  # new moon near J2000
	var y_start_jd : float = calendar_jd_utc( year, 1, 1, 12.0 )
	var y_end_jd : float = calendar_jd_utc( year, 12, 31, 12.0 )
	var k : int = int( floor( ( y_start_jd - anchor_jd ) / synodic ) ) - 1
	while true :
		var nm_jd : float = anchor_jd + float( k ) * synodic
		if nm_jd > y_end_jd + 2.0 :
			break
		if nm_jd >= y_start_jd - 2.0 :
			var peak : Dictionary = find_peak_at_observer( lat_deg, lon_deg, nm_jd, 18.0 )
			if float( peak.get( "obscuration", 0.0 ) ) >= min_obscuration \
					and float( peak.get( "sun_elevation_deg", -90.0 ) ) > 0.0 :
				var dt : Dictionary = jd_to_utc_calendar( float( peak.get( "jd_utc", nm_jd ) ) )
				peak[ "year" ] = int( dt.get( "year", year ) )
				peak[ "month" ] = int( dt.get( "month", 1 ) )
				peak[ "day" ] = int( dt.get( "day", 1 ) )
				peak[ "day_time" ] = float( dt.get( "day_time", 12.0 ) )
				hits.append( peak )
		k += 1
	return hits


static func calendar_jd_utc( y: int, mo: int, d: int, utc_hours: float ) -> float :
	var a : int = ( 14 - mo ) / 12
	var yy : int = y + 4800 - a
	var m : int = mo + 12 * a - 3
	var jdn : int = d + ( 153 * m + 2 ) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
	return float( jdn ) + utc_hours / 24.0 - 0.5


static func jd_to_utc_calendar( jd_utc: float ) -> Dictionary :
	var z : int = int( floor( jd_utc + 0.5 ) )
	var f : float = jd_utc + 0.5 - float( z )
	var a : int = z
	if z >= 2299161 :
		var alpha : int = int( ( float( z ) - 1867216.25 ) / 36524.25 )
		a = z + 1 + alpha - alpha / 4
	var b : int = a + 1524
	var c : int = int( ( float( b ) - 122.1 ) / 365.25 )
	var d : int = int( 365.25 * float( c ) )
	var e : int = int( ( float( b ) - d ) / 30.6001 )
	var day : int = b - d - int( 30.6001 * float( e ) )
	var month : int = e - 1 if e < 14 else e - 13
	var year : int = c - 4716 if month > 2 else c - 4715
	return {
		"year": year,
		"month": month,
		"day": day,
		"day_time": f * 24.0,
	}

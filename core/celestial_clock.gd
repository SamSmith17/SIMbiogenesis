@tool
class_name CelestialClock
extends RefCounted

## Astronomy + timekeeping engine extracted from main.gd.
## Owns the simulated calendar (year/month/day/day_time), observer location,
## DST rules, and all celestial math: Julian day, equation of time, solar and
## lunar positions, sidereal time, lunar phase, and sunrise/sunset times.
## Pure computation — no scene access. Main owns an instance and applies the
## results to lights, sky shader, and environment.

const HOURS_IN_DAY : float = 24.0
const DAYS_IN_YEAR : int = 365

# ==================== DATE/TIME STATE ====================

## Year (1-9999)
var year : int = 2026 :
	set( value ) :
		year = value
		_update_date_from_year_day()

## Month (1-12)
var month : int = 1 :
	set( value ) :
		month = clamp( value, 1, 12 )
		_update_date_from_month_day()

## Day of month (1-31, clamped to valid days for month)
var day : int = 26 :
	set( value ) :
		var max_days = get_days_in_month( month, year )
		day = clamp( value, 1, max_days )

## Time of day in hours (0-24). Rolls the calendar when crossing midnight.
var day_time : float = 12.0 :
	set( value ) :
		day_time = value
		# Handle time going backwards (past midnight into previous day)
		while day_time < 0.0 :
			day_time += HOURS_IN_DAY
			var new_day = day - 1
			if new_day < 1 :
				var new_month = month - 1
				if new_month < 1 :
					new_month = 12
					year -= 1
				month = new_month
				day = get_days_in_month( month, year )
			else :
				day = new_day
		# Handle time going forwards (past midnight into next day)
		while day_time >= HOURS_IN_DAY :
			day_time -= HOURS_IN_DAY
			var days_in_month = get_days_in_month( month, year )
			var new_day = day + 1
			if new_day > days_in_month :
				var new_month = month + 1
				if new_month > 12 :
					new_month = 1
					year += 1
				month = new_month
				day = 1
			else :
				day = new_day

## Day of year (1-365/366, calculated from month/day)
var day_of_year : int :
	get:
		return _calculate_day_of_year( month, day, year )

## Time multiplier. 0 = paused, 1.0 = 1 hour per second, 0.01 = 1x real-time
var time_scale : float = 0.01

# ==================== LOCATION ====================

## Latitude in degrees (-90 to 90). Default: Bombay Beach, CA
var latitude : float = 33.3561

## Longitude in degrees (-180 to 180). Default: Bombay Beach, CA
var longitude : float = -115.7366

## Automatically switch DST on/off based on US rules (2nd Sunday March - 1st Sunday November)
var auto_dst : bool = true

## Manual DST override (only used when auto_dst is false)
var manual_dst : bool = false

# ==================== ASTRONOMICAL PARAMETERS ====================

## Earth's axial tilt (causes seasons)
var planet_axial_tilt : float = 23.44

## Synodic month - time for moon to complete phase cycle
var moon_orbital_period : float = 29.530588

## Day of the lunar cycle to start on (0 = new moon, ~14.76 = full moon)
var moon_phase_offset : float = 0.0

# ==================== INITIALIZATION ====================

## Initialize date and time from the system clock
func init_from_system_time() -> void :
	var datetime : Dictionary = Time.get_datetime_dict_from_system()
	year = datetime.get( "year", 2026 )
	month = datetime.get( "month", 1 )
	day = datetime.get( "day", 26 )
	var hour : int = datetime.get( "hour", 12 )
	var minute : int = datetime.get( "minute", 0 )
	var second : int = datetime.get( "second", 0 )
	day_time = float( hour ) + float( minute ) / 60.0 + float( second ) / 3600.0

## Set the calendar and time-of-day from a Unix timestamp.
func set_from_unix( t_unix: int ) -> void :
	var dt : Dictionary = Time.get_datetime_dict_from_unix_time( t_unix )
	year = int( dt.get( "year", year ) )
	month = int( dt.get( "month", month ) )
	day = int( dt.get( "day", day ) )
	var hour : int = int( dt.get( "hour", 0 ) )
	var minute : int = int( dt.get( "minute", 0 ) )
	var second : int = int( dt.get( "second", 0 ) )
	day_time = float( hour ) + float( minute ) / 60.0 + float( second ) / 3600.0

## Advance the clock by a frame delta (scaled by time_scale).
func advance( delta: float ) -> void :
	day_time += delta * time_scale

# ==================== DST ====================

## Returns true if DST is currently active (either auto-calculated or manual)
func is_dst_active() -> bool :
	if auto_dst :
		return _calculate_dst_for_date( year, month, day, day_time )
	else :
		return manual_dst

## Calculate if DST is active for a given date (US rules)
## DST starts: 2nd Sunday of March at 2:00 AM
## DST ends: 1st Sunday of November at 2:00 AM
func _calculate_dst_for_date( y: int, m: int, d: int, time_hours: float ) -> bool :
	# DST only applies March through November
	if m < 3 or m > 11 :
		return false
	if m > 3 and m < 11 :
		return true

	# March: DST starts on 2nd Sunday at 2:00 AM
	if m == 3 :
		var second_sunday : int = _get_nth_sunday_of_month( y, 3, 2 )
		if d > second_sunday :
			return true
		elif d == second_sunday :
			return time_hours >= 2.0
		else :
			return false

	# November: DST ends on 1st Sunday at 2:00 AM
	if m == 11 :
		var first_sunday : int = _get_nth_sunday_of_month( y, 11, 1 )
		if d < first_sunday :
			return true
		elif d == first_sunday :
			return time_hours < 2.0
		else :
			return false

	return false

## Get the day of month for the Nth Sunday of a given month
func _get_nth_sunday_of_month( y: int, m: int, n: int ) -> int :
	# Find day of week for the 1st of the month (0 = Sunday, 6 = Saturday)
	# Using Zeller's congruence simplified for Gregorian calendar
	var a : int = ( 14 - m ) / 12
	var yy : int = y - a
	var mm : int = m + 12 * a - 2
	var day_of_week_1st : int = ( 1 + yy + yy / 4 - yy / 100 + yy / 400 + ( 31 * mm ) / 12 ) % 7

	# First Sunday of the month
	var first_sunday : int = 1 + ( 7 - day_of_week_1st ) % 7

	# Nth Sunday
	return first_sunday + ( n - 1 ) * 7

# ==================== DATE CALCULATIONS ====================

func _is_leap_year( y: int ) -> bool :
	return ( y % 4 == 0 and y % 100 != 0 ) or ( y % 400 == 0 )

## Get number of days in a month
func get_days_in_month( m: int, y: int ) -> int :
	match m :
		1, 3, 5, 7, 8, 10, 12 :
			return 31
		4, 6, 9, 11 :
			return 30
		2 :
			return 29 if _is_leap_year( y ) else 28
		_ :
			return 31

func _calculate_day_of_year( m: int, d: int, y: int ) -> int :
	var days : int = 0
	for month_num in range( 1, m ) :
		days += get_days_in_month( month_num, y )
	days += d
	return days

func _update_date_from_year_day() -> void :
	# Recalculate month/day from day_of_year
	var target_day : int = _calculate_day_of_year( month, day, year )
	var days_so_far : int = 0
	for m in range( 1, 13 ) :
		var days_in_month = get_days_in_month( m, year )
		if days_so_far + days_in_month >= target_day :
			month = m
			day = target_day - days_so_far
			break
		days_so_far += days_in_month

func _update_date_from_month_day() -> void :
	# Ensure day is valid for the month
	var max_days = get_days_in_month( month, year )
	if day > max_days :
		day = max_days

# ==================== ABSOLUTE TIMECODE ====================
# A single monotonic, reversible number that every time-aware subsystem keys
# off. Absolute hours since proleptic-Gregorian year 1, Jan 1, 00:00. This is a
# pure linear view of (year, day_of_year, day_time) — no new state.

## Days elapsed before Jan 1 of year `y` (proleptic Gregorian, year 1 = 0 days).
func _days_before_year( y: int ) -> int :
	var yy : int = y - 1
	return 365 * yy + yy / 4 - yy / 100 + yy / 400

## Year that contains the given absolute day count (inverse of _days_before_year).
func _year_from_abs_days( total_days: int ) -> int :
	# Approximate with the mean Gregorian year length, then correct exactly.
	var y : int = int( floor( float( total_days ) / 365.2425 ) ) + 1
	if y < 1 :
		y = 1
	while _days_before_year( y ) > total_days :
		y -= 1
	while _days_before_year( y + 1 ) <= total_days :
		y += 1
	return y

## Current clock time as absolute hours since year 1 Jan 1 00:00.
func get_absolute_hours() -> float :
	var doy : int = _calculate_day_of_year( month, day, year )
	return float( _days_before_year( year ) + ( doy - 1 ) ) * HOURS_IN_DAY + day_time

## Set the whole calendar + time-of-day from an absolute-hours value.
## Reversible: get_absolute_hours() after this returns (approximately) `h`.
func set_absolute_hours( h: float ) -> void :
	var total_days : int = int( floor( h / HOURS_IN_DAY ) )
	var rem : float = h - float( total_days ) * HOURS_IN_DAY
	var y : int = _year_from_abs_days( total_days )
	var doy : int = total_days - _days_before_year( y ) + 1   # 1-based day-of-year
	year = y
	# Convert day-of-year → month/day for the resolved year.
	var days_so_far : int = 0
	for m in range( 1, 13 ) :
		var dim : int = get_days_in_month( m, y )
		if days_so_far + dim >= doy :
			month = m
			day = doy - days_so_far
			break
		days_so_far += dim
	day_time = rem

## Decompose an absolute-hours value into calendar fields WITHOUT mutating the
## clock. Pure — used by the batch-render evaluator and CSV observed series so
## they can compute sun/weather at an arbitrary instant off the live clock.
func abs_hours_to_date( h: float ) -> Dictionary :
	var total_days : int = int( floor( h / HOURS_IN_DAY ) )
	var rem : float = h - float( total_days ) * HOURS_IN_DAY
	var y : int = _year_from_abs_days( total_days )
	var doy : int = total_days - _days_before_year( y ) + 1
	var mo : int = 1
	var dd : int = 1
	var days_so_far : int = 0
	for m in range( 1, 13 ) :
		var dim : int = get_days_in_month( m, y )
		if days_so_far + dim >= doy :
			mo = m
			dd = doy - days_so_far
			break
		days_so_far += dim
	return { "year": y, "month": mo, "day": dd, "day_time": rem }

## Convert a Unix timestamp to absolute hours on the same epoch the clock uses.
## Matches set_from_unix()'s convention (UTC datetime fields treated as the
## local calendar), so a loaded CSV lands where CSV playback puts the clock.
func unix_to_abs_hours( t_unix: int ) -> float :
	var dt : Dictionary = Time.get_datetime_dict_from_unix_time( t_unix )
	var y : int = int( dt.get( "year", 1 ) )
	var mo : int = int( dt.get( "month", 1 ) )
	var d : int = int( dt.get( "day", 1 ) )
	var hour : int = int( dt.get( "hour", 0 ) )
	var minute : int = int( dt.get( "minute", 0 ) )
	var second : int = int( dt.get( "second", 0 ) )
	var doy : int = _calculate_day_of_year( mo, d, y )
	var tod : float = float( hour ) + float( minute ) / 60.0 + float( second ) / 3600.0
	return float( _days_before_year( y ) + ( doy - 1 ) ) * HOURS_IN_DAY + tod

# ==================== JULIAN DAY / SOLAR TIME ====================

## Calculate Julian Day Number (days since Jan 1, 4713 BC)
func get_julian_day() -> float :
	var a : int = ( 14 - month ) / 12
	var y : int = year + 4800 - a
	var m : int = month + 12 * a - 3
	var jdn : int = day + ( 153 * m + 2 ) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
	return float( jdn ) + ( day_time / HOURS_IN_DAY ) - 0.5

## Calculate Julian Day in UTC from local clock time
## day_time is treated as local clock time, we convert to UTC
func get_julian_day_utc() -> float :
	return _julian_day_utc_for( year, month, day, day_time )

## Julian Day in UTC for an explicit calendar instant (pure — no member state
## beyond longitude/DST rules). Shared by get_julian_day_utc() and the
## abs-hours evaluator path.
func _julian_day_utc_for( y_in: int, mo: int, d: int, tod: float ) -> float :
	# Local clock time to UTC conversion
	# Base offset from longitude (approximates standard timezone)
	# For Bombay Beach at -115.74°: base offset ≈ 7.716 hours (close to PST = UTC-8)
	var utc_offset_hours : float = -longitude / 15.0

	# DST adjustment: when DST is active, clocks are 1 hour ahead
	# So we subtract 1 hour from the offset to get correct UTC
	if _calculate_dst_for_date( y_in, mo, d, tod ) :
		utc_offset_hours -= 1.0

	var utc_time : float = tod + utc_offset_hours

	# Handle day overflow/underflow
	var day_offset : int = 0
	while utc_time >= 24.0 :
		utc_time -= 24.0
		day_offset += 1
	while utc_time < 0.0 :
		utc_time += 24.0
		day_offset -= 1

	# Calculate base Julian Day Number for the date
	var a : int = ( 14 - mo ) / 12
	var y : int = y_in + 4800 - a
	var m : int = mo + 12 * a - 3
	var jdn : int = d + ( 153 * m + 2 ) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045

	# Add day offset and UTC time fraction
	return float( jdn + day_offset ) + ( utc_time / HOURS_IN_DAY ) - 0.5

## Julian Day (UTC) at an arbitrary absolute-hours instant, off the live clock.
func abs_hours_to_julian_day_utc( h: float ) -> float :
	var dd : Dictionary = abs_hours_to_date( h )
	return _julian_day_utc_for( int( dd[ "year" ] ), int( dd[ "month" ] ),
		int( dd[ "day" ] ), float( dd[ "day_time" ] ) )

## Calculate Equation of Time (correction for sun's position due to Earth's
## elliptical orbit + axial tilt). Returns hours (sundial minus clock).
func get_equation_of_time( jd: float ) -> float :
	var n : float = jd - 2451545.0  # Days since J2000.0
	# Sun's mean anomaly (degrees) — the SAME orbital element used for declination.
	var g : float = fmod( 357.528 + 0.9856003 * n, 360.0 )
	var g_rad : float = deg_to_rad( g )

	# Equation of time in minutes, Wikipedia "alternative calculation":
	#   E = -7.659·sin(g) + 9.863·sin(2g + 3.5932 rad)
	# Both terms are driven by the mean anomaly g, so the second is the true 2nd
	# annual harmonic (obliquity term) and the phase 3.5932 rad (≈205.9°) folds in
	# the longitude of perihelion. The previous form used 2·L + g (with L the mean
	# longitude ≈ g + 282.9°), i.e. a spurious 3rd harmonic, which warped the
	# analemma into an extra self-crossing.
	var eq_time : float = -7.659 * sin( g_rad ) + 9.863 * sin( 2.0 * g_rad + 3.5932 )
	return eq_time / 60.0  # Convert minutes to hours

## Calculate sun's declination (angle from celestial equator)
func get_sun_declination( jd: float ) -> float :
	var n : float = jd - 2451545.0
	var L : float = fmod( 280.460 + 0.9856474 * n, 360.0 )
	var g : float = fmod( 357.528 + 0.9856003 * n, 360.0 )
	var lambda : float = L + 1.915 * sin( deg_to_rad( g ) ) + 0.020 * sin( 2.0 * deg_to_rad( g ) )
	# Use planet_axial_tilt instead of hardcoded Earth value
	var epsilon : float = planet_axial_tilt
	return rad_to_deg( asin( sin( deg_to_rad( epsilon ) ) * sin( deg_to_rad( lambda ) ) ) )

## Convert local clock time to Local Apparent Solar Time
## This accounts for: timezone, longitude offset, DST, and Equation of Time
func get_solar_time() -> float :
	var jd : float = get_julian_day()

	# Standard timezone meridian (Pacific Time = -120°, i.e., UTC-8)
	# We approximate the timezone from longitude, rounding to nearest 15°
	var timezone_meridian : float = round( longitude / 15.0 ) * 15.0

	# Longitude correction: difference between observer's longitude and timezone meridian
	# Positive means sun reaches us BEFORE the timezone standard (earlier solar noon)
	var longitude_correction : float = ( longitude - timezone_meridian ) / 15.0  # in hours

	# DST correction: when DST is active, clocks are 1 hour ahead of standard time
	var dst_correction : float = -1.0 if is_dst_active() else 0.0

	# Equation of Time: corrects for Earth's elliptical orbit and axial tilt
	var eq_time : float = get_equation_of_time( jd )  # already in hours

	# Local Apparent Solar Time
	# Clock Time + Longitude Correction + DST Correction + Equation of Time
	var solar_time : float = day_time + longitude_correction + dst_correction + eq_time

	return solar_time

## Convert solar time to clock time (reverse of get_solar_time)
func solar_time_to_clock_time( solar_time: float ) -> float :
	var jd := get_julian_day()

	# Standard timezone meridian (approximate from longitude)
	var timezone_meridian : float = round( longitude / 15.0 ) * 15.0

	# Longitude correction (reverse sign from get_solar_time)
	var longitude_correction : float = ( longitude - timezone_meridian ) / 15.0

	# DST correction (reverse sign)
	var dst_correction : float = 1.0 if is_dst_active() else 0.0

	# Equation of Time (reverse sign)
	var eq_time : float = get_equation_of_time( jd )

	# Convert solar time to clock time
	var clock_time : float = solar_time - longitude_correction + dst_correction - eq_time

	# Normalize to 0-24 range
	while clock_time < 0.0 :
		clock_time += 24.0
	while clock_time >= 24.0 :
		clock_time -= 24.0

	return clock_time

## Convert a Local Mean Solar Time to clock time. This is solar_time_to_clock_time
## WITHOUT the equation-of-time term. Observing the sun at a FIXED MEAN solar time
## each day (e.g. mean solar noon) is exactly what traces the analemma: the
## equation of time then re-appears as the sun's east/west wander instead of being
## cancelled out. Snapping to apparent solar noon (solar_time_to_clock_time(12))
## instead pins the hour angle to 0 every day, collapsing the figure-eight into a
## vertical line.
##
## Note the DST term keeps the same sign as solar_time_to_clock_time so it cancels
## against get_solar_time()'s DST correction — the resulting sun direction lands on
## mean solar noon regardless of DST, giving a continuous (undistorted) analemma.
func mean_solar_time_to_clock_time( mean_solar_time: float ) -> float :
	var timezone_meridian : float = round( longitude / 15.0 ) * 15.0
	var longitude_correction : float = ( longitude - timezone_meridian ) / 15.0
	var dst_correction : float = 1.0 if is_dst_active() else 0.0

	var clock_time : float = mean_solar_time - longitude_correction + dst_correction

	while clock_time < 0.0 :
		clock_time += 24.0
	while clock_time >= 24.0 :
		clock_time -= 24.0

	return clock_time

# ==================== SUNRISE/SUNSET ====================

## Cache for sunrise/sunset calculation (invalidated when date/location changes)
var _cached_sun_times : Vector2 = Vector2( -1, -1 )
var _cached_sun_times_key : String = ""

## Calculated sunrise hour for current date/location (read-only, in clock time)
var sunrise_hour : float :
	get :
		return _calculate_sunrise_sunset().x

## Calculated sunset hour for current date/location (read-only, in clock time)
var sunset_hour : float :
	get :
		return _calculate_sunrise_sunset().y

## Calculate sunrise and sunset times based on latitude and sun declination
## Returns times in local clock time (accounting for timezone, DST, and equation of time)
func _calculate_sunrise_sunset() -> Vector2 :
	# Create cache key from date, location, and DST state
	var dst_state := 1 if is_dst_active() else 0
	var cache_key := "%d-%d-%d-%.2f-%.2f-%.2f-%d" % [ year, month, day, latitude, longitude, planet_axial_tilt, dst_state ]
	if cache_key == _cached_sun_times_key and _cached_sun_times.x >= 0 :
		return _cached_sun_times

	var jd := get_julian_day()
	var declination := deg_to_rad( get_sun_declination( jd ) )
	var lat_rad := deg_to_rad( latitude )

	# Hour angle at sunrise/sunset (when sun crosses horizon)
	# cos(hour_angle) = -tan(lat) * tan(declination)
	var cos_hour_angle := -tan( lat_rad ) * tan( declination )

	# Handle polar day/night (sun never rises or sets)
	if cos_hour_angle < -1.0 :
		# Polar day - sun never sets
		_cached_sun_times = Vector2( 0.0, 24.0 )
	elif cos_hour_angle > 1.0 :
		# Polar night - sun never rises
		_cached_sun_times = Vector2( 12.0, 12.0 )
	else :
		var hour_angle := acos( cos_hour_angle )
		var hour_angle_hours := rad_to_deg( hour_angle ) / 15.0

		# Solar time: Sunrise = 12 - hour_angle, Sunset = 12 + hour_angle
		var sunrise_solar := 12.0 - hour_angle_hours
		var sunset_solar := 12.0 + hour_angle_hours

		# Convert to clock time
		var sunrise := solar_time_to_clock_time( sunrise_solar )
		var sunset := solar_time_to_clock_time( sunset_solar )

		_cached_sun_times = Vector2( sunrise, sunset )

	_cached_sun_times_key = cache_key
	return _cached_sun_times

# ==================== SIDEREAL TIME / MOON POSITION ====================

## Calculate Local Sidereal Time in degrees (using UTC-based Julian Day)
func get_local_sidereal_time( jd_utc: float ) -> float :
	# Days since J2000.0 (in UTC)
	var d : float = jd_utc - 2451545.0

	# Greenwich Mean Sidereal Time
	var gmst : float = 280.46061837 + 360.98564736629 * d

	# Local Sidereal Time = GMST + longitude (east positive)
	var lst : float = gmst + longitude

	# Normalize to 0-360
	lst = fmod( lst, 360.0 )
	if lst < 0.0 :
		lst += 360.0

	return lst

## Calculate moon's ecliptic coordinates (longitude, latitude)
func get_moon_position( jd_utc: float ) -> Dictionary :
	# Days since J2000.0 (in UTC)
	var d : float = jd_utc - 2451545.0

	# Moon's orbital elements
	var L : float = fmod( 218.316 + 13.176396 * d, 360.0 )  # Mean longitude
	var M : float = fmod( 134.963 + 13.064993 * d, 360.0 )  # Mean anomaly
	var F : float = fmod( 93.272 + 13.229350 * d, 360.0 )   # Argument of latitude

	# Mean elongation from sun
	var D : float = fmod( 297.850 + 12.190749 * d, 360.0 )

	# Sun's mean anomaly
	var Ms : float = fmod( 357.529 + 0.985600 * d, 360.0 )

	# Convert to radians
	var M_rad : float = deg_to_rad( M )
	var F_rad : float = deg_to_rad( F )
	var D_rad : float = deg_to_rad( D )
	var Ms_rad : float = deg_to_rad( Ms )

	# Ecliptic longitude (with main periodic terms)
	var lon : float = L
	lon += 6.289 * sin( M_rad )                    # Equation of center
	lon += 1.274 * sin( 2.0 * D_rad - M_rad )      # Evection
	lon += 0.658 * sin( 2.0 * D_rad )              # Variation
	lon += 0.214 * sin( 2.0 * M_rad )              # Annual equation (partial)
	lon -= 0.186 * sin( Ms_rad )                   # Annual equation
	lon -= 0.114 * sin( 2.0 * F_rad )              # Reduction to ecliptic

	# Ecliptic latitude
	var lat : float = 5.128 * sin( F_rad )
	lat += 0.281 * sin( M_rad + F_rad )
	lat += 0.278 * sin( M_rad - F_rad )

	# Normalize longitude
	lon = fmod( lon, 360.0 )
	if lon < 0.0 :
		lon += 360.0

	return { "longitude": lon, "latitude": lat }

## Convert ecliptic coordinates to equatorial (Right Ascension, Declination)
func ecliptic_to_equatorial( ecl_lon: float, ecl_lat: float ) -> Dictionary :
	# Obliquity of the ecliptic (Earth's axial tilt)
	var epsilon : float = deg_to_rad( planet_axial_tilt )

	var lon_rad : float = deg_to_rad( ecl_lon )
	var lat_rad : float = deg_to_rad( ecl_lat )

	# Convert to equatorial coordinates
	var sin_dec : float = sin( lat_rad ) * cos( epsilon ) + cos( lat_rad ) * sin( epsilon ) * sin( lon_rad )
	sin_dec = clamp( sin_dec, -1.0, 1.0 )
	var dec : float = asin( sin_dec )

	var y : float = sin( lon_rad ) * cos( epsilon ) - tan( lat_rad ) * sin( epsilon )
	var x : float = cos( lon_rad )
	var ra : float = atan2( y, x )

	# Convert RA to degrees (0-360)
	var ra_deg : float = rad_to_deg( ra )
	if ra_deg < 0.0 :
		ra_deg += 360.0

	return { "ra": ra_deg, "dec": rad_to_deg( dec ) }

# ==================== SKY DIRECTIONS ====================

## Direction vector pointing from the scene toward the sun.
## Azimuth convention: 0 = North (-Z), 90° = East (+X), 180° = South (+Z), 270° = West (-X)
func get_sun_direction() -> Vector3 :
	var jd : float = get_julian_day()

	# Get Local Apparent Solar Time from clock time
	var solar_time : float = get_solar_time()

	# Hour angle: 0 at solar noon (solar_time = 12), negative in morning, positive in afternoon
	# Each hour = 15° of Earth rotation
	var hour_angle : float = deg_to_rad( ( solar_time - 12.0 ) * 15.0 )

	# Sun's declination in radians
	var declination : float = deg_to_rad( get_sun_declination( jd ) )
	var lat_rad : float = deg_to_rad( latitude )

	# Calculate sun's altitude using spherical trigonometry
	# This is the proper formula that accounts for latitude, declination, and hour angle
	var sin_altitude : float = sin( lat_rad ) * sin( declination ) + cos( lat_rad ) * cos( declination ) * cos( hour_angle )
	sin_altitude = clamp( sin_altitude, -1.0, 1.0 )
	var altitude : float = asin( sin_altitude )

	# Calculate sun's azimuth (angle from North, clockwise)
	var cos_altitude : float = cos( altitude )
	var cos_azimuth : float = 0.0
	if abs( cos_altitude ) > 0.0001 and abs( cos( lat_rad ) ) > 0.0001 :
		cos_azimuth = ( sin( declination ) - sin( lat_rad ) * sin_altitude ) / ( cos( lat_rad ) * cos_altitude )
		cos_azimuth = clamp( cos_azimuth, -1.0, 1.0 )
	var azimuth : float = acos( cos_azimuth )

	# Azimuth is measured from North; afternoon (hour_angle > 0) means sun is in the west
	if hour_angle > 0.0 :
		azimuth = TAU - azimuth

	# Convert altitude and azimuth to a direction vector
	var sun_dir_x : float = cos_altitude * sin( azimuth )
	var sun_dir_y : float = sin_altitude
	var sun_dir_z : float = -cos_altitude * cos( azimuth )
	return Vector3( sun_dir_x, sun_dir_y, sun_dir_z ).normalized()

## Direction vector pointing from the scene toward the moon.
func get_moon_direction() -> Vector3 :
	# Use UTC-based Julian Day for accurate astronomical calculations
	var jd_utc : float = get_julian_day_utc()

	# Calculate moon's actual celestial position using UTC Julian Day
	var moon_ecl : Dictionary = get_moon_position( jd_utc )
	var moon_eq : Dictionary = ecliptic_to_equatorial( moon_ecl.longitude, moon_ecl.latitude )

	# Get Local Sidereal Time using UTC Julian Day
	var lst : float = get_local_sidereal_time( jd_utc )

	# Calculate hour angle: H = LST - RA
	var moon_hour_angle_deg : float = lst - moon_eq.ra
	# Normalize to -180 to +180
	while moon_hour_angle_deg > 180.0 :
		moon_hour_angle_deg -= 360.0
	while moon_hour_angle_deg < -180.0 :
		moon_hour_angle_deg += 360.0

	var moon_hour_angle : float = deg_to_rad( moon_hour_angle_deg )
	var moon_declination : float = deg_to_rad( moon_eq.dec )
	var lat_rad : float = deg_to_rad( latitude )

	# Calculate moon's altitude using spherical trigonometry (same as sun)
	var sin_altitude : float = sin( lat_rad ) * sin( moon_declination ) + cos( lat_rad ) * cos( moon_declination ) * cos( moon_hour_angle )
	sin_altitude = clamp( sin_altitude, -1.0, 1.0 )
	var altitude : float = asin( sin_altitude )

	# Calculate moon's azimuth
	var cos_altitude : float = cos( altitude )
	var cos_azimuth : float = 0.0
	if abs( cos_altitude ) > 0.0001 and abs( cos( lat_rad ) ) > 0.0001 :
		cos_azimuth = ( sin( moon_declination ) - sin( lat_rad ) * sin_altitude ) / ( cos( lat_rad ) * cos_altitude )
		cos_azimuth = clamp( cos_azimuth, -1.0, 1.0 )
	var azimuth : float = acos( cos_azimuth )

	# Adjust azimuth for western sky
	# Use sin(hour_angle) to determine east vs west - this correctly handles wrap-around
	# sin > 0 means hour angle is in (0, PI) range = western sky (afternoon/evening)
	# sin < 0 means hour angle is in (-PI, 0) or equivalent = eastern sky (morning)
	if sin( moon_hour_angle ) > 0.0 :
		azimuth = TAU - azimuth

	# Convert to direction vector
	var moon_dir_x : float = cos_altitude * sin( azimuth )
	var moon_dir_y : float = sin_altitude
	var moon_dir_z : float = -cos_altitude * cos( azimuth )
	return Vector3( moon_dir_x, moon_dir_y, moon_dir_z ).normalized()

# ==================== LUNAR PHASE ====================

func get_lunar_phase() -> float :
	var jd : float = get_julian_day()
	var known_new_moon_jd : float = 2451549.5  # Approximate new moon near J2000
	var days_since_known_new : float = ( jd - known_new_moon_jd ) + moon_phase_offset
	var lunar_phase : float = fmod( days_since_known_new, moon_orbital_period ) / moon_orbital_period
	if lunar_phase < 0.0 :
		lunar_phase += 1.0
	return lunar_phase

func get_lunar_phase_name() -> String :
	var phase : float = get_lunar_phase()
	if phase < 0.0625 or phase >= 0.9375 :
		return "New Moon"
	elif phase < 0.1875 :
		return "Waxing Crescent"
	elif phase < 0.3125 :
		return "First Quarter"
	elif phase < 0.4375 :
		return "Waxing Gibbous"
	elif phase < 0.5625 :
		return "Full Moon"
	elif phase < 0.6875 :
		return "Waning Gibbous"
	elif phase < 0.8125 :
		return "Last Quarter"
	else :
		return "Waning Crescent"

## Get moon brightness based on phase using realistic non-linear scaling
## Based on the visible illuminated fraction and opposition surge effect
## Returns 0.0 at new moon, 1.0 at full moon
func get_lunar_phase_brightness() -> float :
	var phase : float = get_lunar_phase()
	# Phase goes 0 -> 0.5 (new to full) -> 1.0 (full to new)
	# Convert to phase angle where 0 = new moon, π = full moon
	var phase_angle : float = phase * TAU

	# Calculate illuminated fraction (basic cosine model)
	# At new moon (phase=0): cos(0) = 1, so fraction = 0
	# At full moon (phase=0.5): cos(π) = -1, so fraction = 1
	var illuminated_fraction : float = ( 1.0 - cos( phase_angle ) ) / 2.0

	# Apply opposition surge effect - the moon is disproportionately brighter
	# near full moon due to reduced shadowing on the lunar surface
	# This creates a non-linear brightness curve that peaks sharply at full moon
	# Using a power function to model this effect
	var opposition_surge : float = pow( illuminated_fraction, 0.6 )

	# Additional brightening near full moon (opposition effect adds ~40% at full)
	# This simulates the "opposition surge" observed in lunar photometry
	var full_moon_proximity : float = 1.0 - abs( phase - 0.5 ) * 2.0  # 0 at new/old, 1 at full
	var surge_boost : float = 1.0 + full_moon_proximity * full_moon_proximity * 0.4

	# Combine effects
	var brightness : float = opposition_surge * surge_boost

	# Normalize to 0-1 range (max theoretical value is ~1.4, clamp and rescale)
	brightness = clampf( brightness / 1.4, 0.0, 1.0 )

	return brightness

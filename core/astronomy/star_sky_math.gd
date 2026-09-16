class_name StarSkyMath
extends RefCounted

## Pure static astronomy for the night-sky star field — sidereal time, the
## equatorial<->horizontal basis, and the mapping from a world direction to a
## texel of the equirectangular star map. No scene access, so every line here
## is pinned offline by core/astronomy/star_sky_selftest.gd.
##
## WHY THIS FILE EXISTS. The sky shader used to rotate the view about the
## celestial-pole axis by LST (correct) and then read the texture's
## longitude/latitude off the ROTATED WORLD vector — atan(x,-z) / asin(y) —
## which treats the ZENITH as the texture's pole. That is only self-consistent
## at latitude 90°; at Bombay Beach (33° N) looking straight up sampled the map
## from Dec +90° down to Dec −24° over one night, and no amount of RA/Dec
## "calibration offset" could make the computed reference-star markers land on
## the texture stars for more than an instant. The fix is an explicit equatorial
## basis, built here, pushed to the shader as three vectors, and MIRRORED line
## for line in shader_uv_for_direction() so the selftest can prove the shader
## and the marker math agree.
##
## Conventions (shared with CelestialClock / SolarPosition / LunarPosition):
##   World frame: north = −Z, east = +X, up = +Y.
##   Azimuth 0 = N, 90 = E, clockwise. dir = (cos a·sin A, sin a, −cos a·cos A).
##   Hour angle H is positive WEST, H = LST − RA; RA increases eastward.
##   Equatorial basis at geographic latitude φ (world-frame unit vectors):
##     P (north celestial pole)             = (0,  sin φ, −cos φ)
##     M (equator point on the meridian,
##        due south, altitude 90 − φ)       = (0,  cos φ,  sin φ)
##     E (east point of the equator)        = (1,  0,      0)
##     cross(M, E) == P (right-handed; pinned).
##   Forward:  v = cos δ cos H · M − cos δ sin H · E + sin δ · P
##   Inverse:  δ = asin(v·P),  H = atan2(−v·E, v·M),  RA = wrap360(LST − H)
##
## Texture registration is DATA, never a user setting: the sidecar JSON next to
## the star map (see default_registration()) says which RA sits at u = 0, which
## way RA runs across the image, and whether the north pole is the top row.
## An all-sky map rendered from INSIDE the sphere with north up has east on the
## LEFT, so RA increases leftward (ra_direction = −1) — but the prep tool
## (tools/starmap_prepare.py) DETECTS that from the bright stars rather than
## assuming it, and the shader follows the sidecar.
##
## Sidereal time: Meeus, "Astronomical Algorithms" 2nd ed., eq. 12.4 (mean
## sidereal time, incl. the T² / T³ terms). Mean, not apparent — the equation of
## the equinoxes is ≤ 0.0048°, far below anything the star field can show.

const J2000_JD : float = 2451545.0
const _DEG2RAD : float = PI / 180.0
const _RAD2DEG : float = 180.0 / PI

## Registration sidecar schema version written by tools/starmap_prepare.py.
const REGISTRATION_SCHEMA : int = 1


# ==================== ANGLES / SIDEREAL TIME ====================

static func wrap360( x: float ) -> float :
	var r : float = fmod( x, 360.0 )
	if r < 0.0 :
		r += 360.0
	return r


## Greenwich Mean Sidereal Time in degrees (Meeus eq. 12.4).
static func gmst_deg( jd_utc: float ) -> float :
	var d : float = jd_utc - J2000_JD
	var T : float = d / 36525.0
	var gmst : float = 280.46061837 + 360.98564736629 * d \
		+ 0.000387933 * T * T - T * T * T / 38710000.0
	return wrap360( gmst )


## Local Mean Sidereal Time in degrees; longitude east-positive.
static func local_sidereal_deg( jd_utc: float, lon_east_deg: float ) -> float :
	return wrap360( gmst_deg( jd_utc ) + lon_east_deg )


## Hour angle in (−180, 180], positive west of the meridian.
static func hour_angle_deg( lst_deg: float, ra_deg: float ) -> float :
	var h : float = wrap360( lst_deg - ra_deg )
	if h > 180.0 :
		h -= 360.0
	return h


# ==================== EQUATORIAL BASIS ====================

## World-frame unit vectors of the equatorial frame at geographic latitude φ.
## Returns {"pole": P, "meridian": M, "east": E} — see the header for the
## definitions. For φ < 0 the NCP is below the northern horizon and −P (the
## SCP) is above the southern one; nothing here special-cases the hemisphere.
static func equatorial_basis( lat_deg: float ) -> Dictionary :
	var phi : float = lat_deg * _DEG2RAD
	var s : float = sin( phi )
	var c : float = cos( phi )
	return {
		"pole": Vector3( 0.0, s, -c ),
		"meridian": Vector3( 0.0, c, s ),
		"east": Vector3( 1.0, 0.0, 0.0 ),
	}


## RA/Dec -> world direction via the basis (the formula the shader inverts).
static func direction_from_equatorial( ra_deg: float, dec_deg: float, lst_deg: float, lat_deg: float ) -> Vector3 :
	var b : Dictionary = equatorial_basis( lat_deg )
	var h : float = hour_angle_deg( lst_deg, ra_deg ) * _DEG2RAD
	var d : float = dec_deg * _DEG2RAD
	var cd : float = cos( d )
	var v : Vector3 = ( b[ "meridian" ] as Vector3 ) * ( cd * cos( h ) ) \
		- ( b[ "east" ] as Vector3 ) * ( cd * sin( h ) ) \
		+ ( b[ "pole" ] as Vector3 ) * sin( d )
	return v.normalized()


## World direction -> {"ra", "dec", "hour_angle"} (degrees) via the basis.
static func equatorial_from_direction( dir: Vector3, lst_deg: float, lat_deg: float ) -> Dictionary :
	var b : Dictionary = equatorial_basis( lat_deg )
	var v : Vector3 = dir.normalized()
	var sd : float = clampf( v.dot( b[ "pole" ] ), -1.0, 1.0 )
	var dec : float = asin( sd ) * _RAD2DEG
	var h : float = atan2( -v.dot( b[ "east" ] ), v.dot( b[ "meridian" ] ) ) * _RAD2DEG
	return {
		"ra": wrap360( lst_deg - h ),
		"dec": dec,
		"hour_angle": h,
	}


# ==================== HORIZONTAL COORDINATES (legacy spherical-trig form) ====================

## Classic hour-angle / altitude / azimuth form (Meeus Ch. 13). Kept as an
## INDEPENDENT derivation of direction_from_equatorial so the selftest can
## prove the basis form against it; this is what the reference-star markers
## used before the basis existed.
static func equatorial_to_horizontal( ra_deg: float, dec_deg: float, lst_deg: float, lat_deg: float ) -> Dictionary :
	var ha : float = hour_angle_deg( lst_deg, ra_deg )
	var ha_rad : float = ha * _DEG2RAD
	var dec_rad : float = dec_deg * _DEG2RAD
	var lat_rad : float = lat_deg * _DEG2RAD
	var sin_alt : float = sin( lat_rad ) * sin( dec_rad ) + cos( lat_rad ) * cos( dec_rad ) * cos( ha_rad )
	sin_alt = clampf( sin_alt, -1.0, 1.0 )
	var altitude : float = asin( sin_alt )
	var cos_alt : float = cos( altitude )
	var cos_az : float = 0.0
	if absf( cos_alt ) > 0.0001 and absf( cos( lat_rad ) ) > 0.0001 :
		cos_az = ( sin( dec_rad ) - sin( lat_rad ) * sin_alt ) / ( cos( lat_rad ) * cos_alt )
		cos_az = clampf( cos_az, -1.0, 1.0 )
	var azimuth : float = acos( cos_az )
	if sin( ha_rad ) > 0.0 :
		azimuth = TAU - azimuth
	return { "altitude": altitude * _RAD2DEG, "azimuth": azimuth * _RAD2DEG }


## Altitude/azimuth (degrees) -> world direction.
static func horizontal_to_direction( altitude_deg: float, azimuth_deg: float ) -> Vector3 :
	var alt_rad : float = altitude_deg * _DEG2RAD
	var az_rad : float = azimuth_deg * _DEG2RAD
	var cos_alt : float = cos( alt_rad )
	return Vector3( cos_alt * sin( az_rad ), sin( alt_rad ), -cos_alt * cos( az_rad ) ).normalized()


## World direction -> {"altitude", "azimuth"} (degrees, az 0..360).
static func direction_to_horizontal( dir: Vector3 ) -> Dictionary :
	var v : Vector3 = dir.normalized()
	var alt : float = asin( clampf( v.y, -1.0, 1.0 ) ) * _RAD2DEG
	var az : float = wrap360( atan2( v.x, -v.z ) * _RAD2DEG )
	return { "altitude": alt, "azimuth": az }


# ==================== TEXTURE REGISTRATION ====================

## The registration a plate-carrée export is ASSUMED to have when no sidecar
## exists: RA 0h at the left edge, RA increasing leftward (inside view), NCP on
## the top row, J2000 epoch. `sidecar_found` tells the UI whether this is a
## measured fact or the assumption.
static func default_registration() -> Dictionary :
	return {
		"ra_deg_at_u0": 0.0,
		"ra_direction": -1,
		"north_up": true,
		"epoch": "J2000",
		"width": 0,
		"height": 0,
		"residual_px": NAN,
		"sidecar_found": false,
	}


## Path of the sidecar JSON that describes a star-map image (same directory,
## same basename, `.json` extension).
static func sidecar_path_for( image_path: String ) -> String :
	if image_path.is_empty() :
		return ""
	var ext : String = image_path.get_extension()
	if ext.is_empty() :
		return image_path + ".json"
	return image_path.substr( 0, image_path.length() - ext.length() ) + "json"


## Read the sidecar next to `image_path` (res:// or user:// or absolute) and
## merge it over default_registration(). A missing or malformed file returns
## the defaults with `sidecar_found = false` — never an error, because the
## shader must still draw SOMETHING sensible for a map that has no sidecar.
static func load_registration( image_path: String ) -> Dictionary :
	var reg : Dictionary = default_registration()
	var path : String = sidecar_path_for( image_path )
	if path.is_empty() or not FileAccess.file_exists( path ) :
		return reg
	var f := FileAccess.open( path, FileAccess.READ )
	if f == null :
		return reg
	var parsed : Variant = JSON.parse_string( f.get_as_text() )
	f.close()
	if not ( parsed is Dictionary ) :
		return reg
	return registration_from_dict( parsed as Dictionary )


## Pure form of load_registration() over an already-parsed sidecar dict.
static func registration_from_dict( d: Dictionary ) -> Dictionary :
	var reg : Dictionary = default_registration()
	if d.has( "ra_deg_at_u0" ) :
		reg[ "ra_deg_at_u0" ] = wrap360( float( d[ "ra_deg_at_u0" ] ) )
	if d.has( "ra_direction" ) :
		reg[ "ra_direction" ] = -1 if float( d[ "ra_direction" ] ) < 0.0 else 1
	if d.has( "north_up" ) :
		reg[ "north_up" ] = bool( d[ "north_up" ] )
	if d.has( "epoch" ) :
		reg[ "epoch" ] = str( d[ "epoch" ] )
	if d.has( "width" ) :
		reg[ "width" ] = int( d[ "width" ] )
	if d.has( "height" ) :
		reg[ "height" ] = int( d[ "height" ] )
	var r : Variant = d.get( "registration", null )
	if r is Dictionary and ( r as Dictionary ).has( "max_residual_px" ) :
		reg[ "residual_px" ] = float( ( r as Dictionary )[ "max_residual_px" ] )
	reg[ "sidecar_found" ] = true
	return reg


## RA/Dec (degrees) -> texture UV under a registration dict.
static func uv_from_equatorial( ra_deg: float, dec_deg: float, reg: Dictionary ) -> Vector2 :
	var ra0 : float = float( reg.get( "ra_deg_at_u0", 0.0 ) )
	var dirn : float = -1.0 if float( reg.get( "ra_direction", -1 ) ) < 0.0 else 1.0
	var u : float = fposmod( ( ra_deg - ra0 ) * dirn / 360.0, 1.0 )
	var v : float = 0.5 - dec_deg / 180.0
	if not bool( reg.get( "north_up", true ) ) :
		v = 1.0 - v
	return Vector2( u, v )


## Texture UV -> {"ra", "dec"} (degrees); inverse of uv_from_equatorial.
static func equatorial_from_uv( uv: Vector2, reg: Dictionary ) -> Dictionary :
	var ra0 : float = float( reg.get( "ra_deg_at_u0", 0.0 ) )
	var dirn : float = -1.0 if float( reg.get( "ra_direction", -1 ) ) < 0.0 else 1.0
	var v : float = uv.y
	if not bool( reg.get( "north_up", true ) ) :
		v = 1.0 - v
	return {
		"ra": wrap360( ra0 + uv.x * 360.0 * dirn ),
		"dec": ( 0.5 - v ) * 180.0,
	}


## Continuous pixel coordinates of an RA/Dec on a w×h image. Pixel (i, j)
## covers [i, i+1) × [j, j+1), so its centre is (i + 0.5, j + 0.5) — the same
## convention tools/starmap_prepare.py uses for its blob centroids.
static func pixel_from_equatorial( ra_deg: float, dec_deg: float, reg: Dictionary, width: int, height: int ) -> Vector2 :
	var uv : Vector2 = uv_from_equatorial( ra_deg, dec_deg, reg )
	return Vector2( uv.x * float( width ), uv.y * float( height ) )


## LINE-FOR-LINE mirror of the star block in sky.gdshader. If the shader
## changes, this changes with it, and the selftest's "shader mirror" group is
## what proves the shader still agrees with the marker math.
static func shader_uv_for_direction( dir: Vector3, basis: Dictionary, lst_deg: float, reg: Dictionary ) -> Vector2 :
	var v : Vector3 = dir.normalized()
	var pole : Vector3 = basis[ "pole" ]
	var meridian : Vector3 = basis[ "meridian" ]
	var east : Vector3 = basis[ "east" ]
	# shader: float _dec = asin( clamp( dot( _v, stars_axis_pole ), -1.0, 1.0 ) );
	var dec : float = asin( clampf( v.dot( pole ), -1.0, 1.0 ) )
	# shader: float _ha = atan( -dot( _v, stars_axis_east ), dot( _v, stars_axis_meridian ) );
	var ha : float = atan2( -v.dot( east ), v.dot( meridian ) )
	# shader: float _ra = radians( stars_lst ) - _ha;
	var ra : float = lst_deg * _DEG2RAD - ha
	# shader: float _u = fract( ( _ra - radians( stars_ra_at_u0_deg ) ) * stars_ra_direction / TAU );
	var ra0 : float = float( reg.get( "ra_deg_at_u0", 0.0 ) ) * _DEG2RAD
	var dirn : float = -1.0 if float( reg.get( "ra_direction", -1 ) ) < 0.0 else 1.0
	var u : float = fposmod( ( ra - ra0 ) * dirn / TAU, 1.0 )
	# shader: float _vv = 0.5 - _dec / PI; if( stars_north_up < 0.5 ) _vv = 1.0 - _vv;
	var vv : float = 0.5 - dec / PI
	if not bool( reg.get( "north_up", true ) ) :
		vv = 1.0 - vv
	return Vector2( u, vv )


## Human-readable one-liner for the settings tab.
static func registration_summary( reg: Dictionary ) -> String :
	if not bool( reg.get( "sidecar_found", false ) ) :
		return "no sidecar — assuming plate-carrée defaults (RA 0h at left, north up)"
	var res : float = float( reg.get( "residual_px", NAN ) )
	var res_txt : String = "n/a" if is_nan( res ) else "%.1f px" % res
	return "%s · RA %s · %s · RA0 %.1f° · fit %s" % [
		str( reg.get( "epoch", "?" ) ),
		"←" if int( reg.get( "ra_direction", -1 ) ) < 0 else "→",
		"north up" if bool( reg.get( "north_up", true ) ) else "north DOWN",
		float( reg.get( "ra_deg_at_u0", 0.0 ) ),
		res_txt,
	]

extends SceneTree

## Offline deterministic selftest for the night-sky star field:
## StarSkyMath (core/astronomy/), the CelestialClock timezone contract the
## sun and the stars now SHARE, and the shipped star-map asset + its sidecar.
##
## What this file exists to freeze:
##   * GMST against Meeus's own worked examples (12.a / 12.b) — the one
##     number every star, moon and planet position hangs off.
##   * The equatorial BASIS form of RA/Dec -> world direction against the
##     independent hour-angle/alt/az derivation. The sky shader used to take
##     the texture latitude off the rotated WORLD vector (the zenith as the
##     texture pole), which is only right at latitude 90°; the basis form is
##     what the shader now inverts, and this pin is what keeps the shader and
##     the reference-star markers on the same sky.
##   * A line-for-line GDScript mirror of the shader's star block
##     (StarSkyMath.shader_uv_for_direction) against the pure UV mapping —
##     edit the shader, edit the mirror, or this fails.
##   * The "one sky" property: CelestialClock.get_sun_direction() (zone-time
##     path) and SolarPosition at get_julian_day_utc() (UTC path) point at the
##     same sun. Before the timezone unification they disagreed by ~4° at
##     Bombay Beach because one used the rounded meridian and the other the
##     exact longitude.
##   * The star map itself: 2:1, pole rows black (no baked-in Stellarium GUI),
##     sidecar present and consistent. These checks are RED until
##     tools/starmap_prepare.py has produced assets/sky/starmap_equirect_8k.png.
##
## Carries EXPECTED_CHECKS because a Godot runtime error aborts the enclosing
## test function while the suite still prints PASS.
##
## Run: Godot.exe.exe --headless --path . --import   (once, new class_names)
##      Godot.exe.exe --headless --path . --script core/astronomy/star_sky_selftest.gd

const EXPECTED_CHECKS := 89

const STARMAP_PATH := "res://assets/sky/starmap_equirect_8k.png"

## J2000 catalog (degrees). Same values as StarSystem.REFERENCE_STARS.
const STARS := {
	"polaris":    { "ra": 37.954,  "dec": 89.264 },
	"dubhe":      { "ra": 165.932, "dec": 61.751 },
	"merak":      { "ra": 165.460, "dec": 56.382 },
	"betelgeuse": { "ra": 88.793,  "dec": 7.407 },
	"rigel":      { "ra": 78.634,  "dec": -8.202 },
	"bellatrix":  { "ra": 81.283,  "dec": 6.350 },
	"sirius":     { "ra": 101.287, "dec": -16.716 },
	"vega":       { "ra": 279.235, "dec": 38.784 },
	"arcturus":   { "ra": 213.915, "dec": 19.182 },
	"capella":    { "ra": 79.172,  "dec": 45.998 },
	"procyon":    { "ra": 114.825, "dec": 5.225 },
	"acrux":      { "ra": 186.650, "dec": -63.099 },
}

const LAT_BB := 33.3561      # Bombay Beach
const LON_BB := -115.7366
const LAT_PERTH := -31.95
const LON_PERTH := 115.86

var _fails := 0
var _checks := 0


func _check( name: String, cond: bool, detail: String = "" ) -> void :
	_checks += 1
	if not cond :
		_fails += 1
		push_error( "FAIL: %s  %s" % [ name, detail ] )


func _near( a: float, b: float, eps: float ) -> bool :
	return absf( a - b ) <= eps


func _near_v3( a: Vector3, b: Vector3, eps: float ) -> bool :
	return ( a - b ).length() <= eps


func _ang_near( a: float, b: float, eps: float ) -> bool :
	# angular closeness modulo 360
	var d : float = fposmod( a - b + 180.0, 360.0 ) - 180.0
	return absf( d ) <= eps


func _initialize() -> void :
	_test_gmst()
	_test_basis()
	_test_equatorial_to_horizontal()
	_test_basis_vs_legacy()
	_test_uv_registration()
	_test_shader_mirror()
	_test_timezone()
	_test_planet_star_frame()
	_test_asset()
	if EXPECTED_CHECKS > 0 and _checks != EXPECTED_CHECKS :
		_fails += 1
		push_error( "FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [ EXPECTED_CHECKS, _checks ] )
	if _fails == 0 :
		print( "STAR SKY SELFTEST PASS  (%d checks)" % _checks )
	else :
		print( "STAR SKY SELFTEST FAIL  (%d of %d checks failed)" % [ _fails, _checks ] )
	quit( 1 if _fails > 0 else 0 )


# ==================== GMST / LST ====================

func _test_gmst() -> void :
	# Meeus example 12.a: 1987 April 10, 0h UT -> GMST 13h 10m 46.3668s
	var jd_a : float = 2446895.5
	var g_a : float = StarSkyMath.gmst_deg( jd_a )
	var want_a : float = ( 13.0 + 10.0 / 60.0 + 46.3668 / 3600.0 ) * 15.0   # 197.693195°
	_check( "GMST Meeus 12.a", _near( g_a, want_a, 1e-4 ), "%.6f vs %.6f" % [ g_a, want_a ] )
	# Meeus example 12.b: 1987 April 10, 19h 21m 00s UT -> GMST 8h 34m 57.0896s
	var jd_b : float = jd_a + ( 19.0 + 21.0 / 60.0 ) / 24.0
	var g_b : float = StarSkyMath.gmst_deg( jd_b )
	var want_b : float = ( 8.0 + 34.0 / 60.0 + 57.0896 / 3600.0 ) * 15.0     # 128.737873°
	_check( "GMST Meeus 12.b", _near( g_b, want_b, 1e-4 ), "%.6f vs %.6f" % [ g_b, want_b ] )
	# Sidereal day: one civil day advances GMST by 360.98564736629° ≡ 0.98564736629°
	var rate : float = fposmod( StarSkyMath.gmst_deg( jd_a + 1.0 ) - g_a, 360.0 )
	_check( "GMST daily rate", _near( rate, 0.98564736629, 1e-7 ), "%.9f" % rate )
	# LST = GMST + east longitude
	_check( "LST adds east longitude", _ang_near( StarSkyMath.local_sidereal_deg( jd_a, 90.0 ), g_a + 90.0, 1e-9 ) )
	_check( "LST west longitude", _ang_near( StarSkyMath.local_sidereal_deg( jd_a, -115.7366 ), g_a - 115.7366, 1e-9 ) )
	# Hour angle sign/range
	_check( "HA positive west", _near( StarSkyMath.hour_angle_deg( 100.0, 40.0 ), 60.0, 1e-9 ) )
	_check( "HA wraps to (-180,180]", _near( StarSkyMath.hour_angle_deg( 10.0, 200.0 ), 170.0, 1e-9 ) )
	_check( "HA exactly 180 stays 180", _near( StarSkyMath.hour_angle_deg( 180.0, 0.0 ), 180.0, 1e-9 ) )
	# CelestialClock delegates
	var clk := CelestialClock.new()
	clk.longitude = LON_BB
	var l1 : float = clk.get_local_sidereal_time( jd_b )
	var l2 : float = StarSkyMath.local_sidereal_deg( jd_b, LON_BB )
	_check( "clock LST delegates to StarSkyMath", _ang_near( l1, l2, 1e-9 ), "%.9f vs %.9f" % [ l1, l2 ] )
	# SolarPosition keeps its own inline eq. 12.4 — prove they agree via hour angle:
	# at the sun's RA the SPA azimuth must be 180 (transit) when LST == RA; instead
	# pin the cheaper identity: the clock's LST equals the LST SolarPosition would
	# compute (same formula). Do it by evaluating GMST at two epochs 100 years apart
	# and checking the T²/T³ terms are present (linear formula would differ by >1e-3°).
	var far_jd : float = J2000_PLUS_CENTURY
	var full : float = StarSkyMath.gmst_deg( far_jd )
	var linear : float = fposmod( 280.46061837 + 360.98564736629 * ( far_jd - 2451545.0 ), 360.0 )
	_check( "GMST carries the T² term", not _near( full, linear, 1e-4 ) and _near( full, linear + 0.000387933, 1e-4 ),
		"full %.6f linear %.6f" % [ full, linear ] )


const J2000_PLUS_CENTURY : float = 2451545.0 + 36525.0


# ==================== BASIS ====================

func _test_basis() -> void :
	var b : Dictionary = StarSkyMath.equatorial_basis( LAT_BB )
	var P : Vector3 = b[ "pole" ]
	var M : Vector3 = b[ "meridian" ]
	var E : Vector3 = b[ "east" ]
	var max_dot : float = maxf( absf( P.dot( M ) ), maxf( absf( P.dot( E ) ), absf( M.dot( E ) ) ) )
	_check( "basis orthogonal", max_dot < 1e-9, str( max_dot ) )
	var max_len : float = maxf( absf( P.length() - 1.0 ), maxf( absf( M.length() - 1.0 ), absf( E.length() - 1.0 ) ) )
	_check( "basis unit length", max_len < 1e-9, str( max_len ) )
	_check( "basis right-handed cross(M,E)==P", _near_v3( M.cross( E ), P, 1e-9 ), str( M.cross( E ) ) )
	# Vector3 is float32: ~1e-5° is the honest floor for anything that went through one.
	_check( "pole elevation == latitude", _near( asin( P.y ) * 180.0 / PI, LAT_BB, 1e-4 ), "%.7f" % ( asin( P.y ) * 180.0 / PI ) )
	_check( "pole is due north", P.x == 0.0 and P.z < 0.0 )
	_check( "meridian point is due south", M.x == 0.0 and M.z > 0.0 )
	var b90 : Dictionary = StarSkyMath.equatorial_basis( 90.0 )
	_check( "lat 90: pole == UP", _near_v3( b90[ "pole" ], Vector3.UP, 1e-9 ) )
	var b0 : Dictionary = StarSkyMath.equatorial_basis( 0.0 )
	_check( "lat 0: pole on the north horizon", _near_v3( b0[ "pole" ], Vector3( 0, 0, -1 ), 1e-9 ) )
	_check( "lat 0: meridian point == zenith", _near_v3( b0[ "meridian" ], Vector3.UP, 1e-9 ) )
	var bs : Dictionary = StarSkyMath.equatorial_basis( LAT_PERTH )
	var Ps : Vector3 = bs[ "pole" ]
	_check( "lat -31.95: NCP below horizon", Ps.y < 0.0 )
	_check( "lat -31.95: SCP above the south horizon", ( -Ps ).y > 0.0 and ( -Ps ).z > 0.0 )


# ==================== EQUATORIAL -> HORIZONTAL ====================

func _test_equatorial_to_horizontal() -> void :
	# Polaris altitude ≈ latitude at every hour angle (0.736° off the pole).
	var worst_alt : float = 0.0
	var worst_az : float = 0.0
	for lst in [ 0.0, 90.0, 180.0, 270.0 ] :
		var h : Dictionary = StarSkyMath.equatorial_to_horizontal( STARS.polaris.ra, STARS.polaris.dec, lst, LAT_BB )
		worst_alt = maxf( worst_alt, absf( float( h.altitude ) - LAT_BB ) )
		var az_off : float = absf( fposmod( float( h.azimuth ) + 180.0, 360.0 ) - 180.0 )
		worst_az = maxf( worst_az, az_off )
	_check( "Polaris altitude ≈ latitude (all LST)", worst_alt <= 0.74, "%.3f" % worst_alt )
	_check( "Polaris azimuth ≈ north (all LST)", worst_az <= 1.0, "%.3f" % worst_az )
	# Sirius transits due south at alt 90 − φ + δ
	var s : Dictionary = StarSkyMath.equatorial_to_horizontal( STARS.sirius.ra, STARS.sirius.dec, STARS.sirius.ra, LAT_BB )
	_check( "Sirius transit altitude", _near( float( s.altitude ), 90.0 - LAT_BB + STARS.sirius.dec, 1e-6 ), "%.6f" % float( s.altitude ) )
	# acos is ill-conditioned at 0/180 (acos(1-ε) ~ sqrt(2ε)), so transit azimuths get 1e-4.
	_check( "Sirius transit due south", _near( float( s.azimuth ), 180.0, 1e-4 ), "%.6f" % float( s.azimuth ) )
	# Dubhe (δ > φ) transits NORTH of the zenith
	var d : Dictionary = StarSkyMath.equatorial_to_horizontal( STARS.dubhe.ra, STARS.dubhe.dec, STARS.dubhe.ra, LAT_BB )
	_check( "Dubhe transit altitude", _near( float( d.altitude ), 90.0 + LAT_BB - STARS.dubhe.dec, 1e-6 ), "%.6f" % float( d.altitude ) )
	_check( "Dubhe transit due north", _ang_near( float( d.azimuth ), 0.0, 1e-4 ), "%.6f" % float( d.azimuth ) )
	# A star on the equator at H = −90 (6h before transit) rises due east
	var e : Dictionary = StarSkyMath.equatorial_to_horizontal( 100.0, 0.0, 10.0, LAT_BB )
	_check( "equator star at H=-90 on the horizon", _near( float( e.altitude ), 0.0, 1e-6 ), "%.6f" % float( e.altitude ) )
	_check( "equator star at H=-90 due east", _near( float( e.azimuth ), 90.0, 1e-6 ), "%.6f" % float( e.azimuth ) )
	# …and at H = +90 it sets due west
	var w : Dictionary = StarSkyMath.equatorial_to_horizontal( 10.0, 0.0, 100.0, LAT_BB )
	_check( "equator star at H=+90 due west", _near( float( w.azimuth ), 270.0, 1e-6 ), "%.6f" % float( w.azimuth ) )
	# Southern site: Acrux transit, Polaris never rises
	var a : Dictionary = StarSkyMath.equatorial_to_horizontal( STARS.acrux.ra, STARS.acrux.dec, STARS.acrux.ra, LAT_PERTH )
	_check( "Acrux transit altitude at Perth", _near( float( a.altitude ), 90.0 - absf( LAT_PERTH - STARS.acrux.dec ), 1e-6 ), "%.6f" % float( a.altitude ) )
	_check( "Acrux transit due south at Perth", _near( float( a.azimuth ), 180.0, 1e-4 ), "%.6f" % float( a.azimuth ) )
	var pp : Dictionary = StarSkyMath.equatorial_to_horizontal( STARS.polaris.ra, STARS.polaris.dec, 200.0, LAT_PERTH )
	_check( "Polaris below horizon at Perth", _near( float( pp.altitude ), LAT_PERTH, 0.74 ), "%.3f" % float( pp.altitude ) )
	# direction <-> horizontal round trip
	var dir : Vector3 = StarSkyMath.horizontal_to_direction( 37.5, 212.25 )
	var back : Dictionary = StarSkyMath.direction_to_horizontal( dir )
	_check( "horizontal round trip", _near( float( back.altitude ), 37.5, 1e-6 ) and _near( float( back.azimuth ), 212.25, 1e-6 ),
		"%s" % str( back ) )
	_check( "az 90 is +X", _near_v3( StarSkyMath.horizontal_to_direction( 0.0, 90.0 ), Vector3.RIGHT, 1e-9 ) )
	_check( "az 0 is -Z", _near_v3( StarSkyMath.horizontal_to_direction( 0.0, 0.0 ), Vector3( 0, 0, -1 ), 1e-9 ) )


# ==================== BASIS FORM == LEGACY FORM (the bug-B pin) ====================

func _test_basis_vs_legacy() -> void :
	var worst : float = 0.0
	var worst_label : String = ""
	var worst_rt : float = 0.0
	for lat in [ LAT_BB, LAT_PERTH, 0.0 ] :
		for lst in [ 0.0, 123.4, 200.0, 359.0 ] :
			for key in STARS.keys() :
				var st : Dictionary = STARS[ key ]
				var v_basis : Vector3 = StarSkyMath.direction_from_equatorial( st.ra, st.dec, lst, lat )
				var h : Dictionary = StarSkyMath.equatorial_to_horizontal( st.ra, st.dec, lst, lat )
				var v_legacy : Vector3 = StarSkyMath.horizontal_to_direction( h.altitude, h.azimuth )
				var ang : float = v_basis.angle_to( v_legacy )
				if ang > worst :
					worst = ang
					worst_label = "%s lat %.2f lst %.1f" % [ key, lat, lst ]
				var eq : Dictionary = StarSkyMath.equatorial_from_direction( v_basis, lst, lat )
				# RA error is a great-circle error only after × cos(dec): at Polaris a
				# float32 direction turns 1e-5° of sky into 8e-4° of RA.
				var dra : float = absf( fposmod( float( eq.ra ) - st.ra + 180.0, 360.0 ) - 180.0 ) * cos( float( st.dec ) * PI / 180.0 )
				var err : float = maxf( dra, absf( float( eq.dec ) - st.dec ) )
				worst_rt = maxf( worst_rt, err )
	# float32 Vector3 in the loop: 1e-5 rad / 1e-4 deg is the honest floor (≈ 0.04 arcsec / 0.4 arcsec).
	_check( "basis form == legacy alt/az form (12 stars × 4 LST × 3 lat)", worst < 1e-5, "%.10f rad at %s" % [ worst, worst_label ] )
	# 1e-3°: float32 asin(v·P) at Polaris (|v·P| ≈ 0.99992) amplifies a 6e-8 dot error
	# ~78× into ~3e-4° of declination. The GPU does the same sum in float32 and it is
	# 0.007 px on the 8k map — but it is why this pin cannot be 1e-4.
	_check( "equatorial round trip through the basis", worst_rt < 1e-3, "%.10f deg" % worst_rt )
	# Hour angle sign through the basis: a star just WEST of the meridian has H > 0
	var eq_w : Dictionary = StarSkyMath.equatorial_from_direction( StarSkyMath.horizontal_to_direction( 40.0, 200.0 ), 100.0, LAT_BB )
	_check( "west of meridian -> H > 0", float( eq_w.hour_angle ) > 0.0, str( eq_w ) )
	var eq_e : Dictionary = StarSkyMath.equatorial_from_direction( StarSkyMath.horizontal_to_direction( 40.0, 160.0 ), 100.0, LAT_BB )
	_check( "east of meridian -> H < 0", float( eq_e.hour_angle ) < 0.0, str( eq_e ) )
	# The zenith has dec == latitude, always (this is exactly what the old shader got wrong)
	for lst in [ 0.0, 90.0, 180.0, 270.0 ] :
		var z : Dictionary = StarSkyMath.equatorial_from_direction( Vector3.UP, lst, LAT_BB )
		_check( "zenith dec == latitude at LST %.0f" % lst, _near( float( z.dec ), LAT_BB, 1e-4 ), "%.6f" % float( z.dec ) )


# ==================== UV REGISTRATION ====================

func _test_uv_registration() -> void :
	var reg : Dictionary = StarSkyMath.default_registration()
	_check( "default registration is the inside-view convention", int( reg.ra_direction ) == -1 and bool( reg.north_up ) and not bool( reg.sidecar_found ) )
	var uv0 : Vector2 = StarSkyMath.uv_from_equatorial( 0.0, 0.0, reg )
	_check( "RA0 / dec 0 -> (0, 0.5)", _near( uv0.x, 0.0, 1e-9 ) and _near( uv0.y, 0.5, 1e-9 ), str( uv0 ) )
	_check( "dec +90 -> v 0 (top row)", _near( StarSkyMath.uv_from_equatorial( 12.0, 90.0, reg ).y, 0.0, 1e-9 ) )
	_check( "dec -90 -> v 1 (bottom row)", _near( StarSkyMath.uv_from_equatorial( 12.0, -90.0, reg ).y, 1.0, 1e-9 ) )
	var u_a : float = StarSkyMath.uv_from_equatorial( 100.0, 0.0, reg ).x
	var u_b : float = StarSkyMath.uv_from_equatorial( 110.0, 0.0, reg ).x
	# Vector2 is float32 too: 1e-6 in UV is ~0.008 px on an 8k map.
	_check( "ra_direction -1: +RA moves LEFT", _near( fposmod( u_b - u_a, 1.0 ), 1.0 - 10.0 / 360.0, 1e-6 ), "%.6f -> %.6f" % [ u_a, u_b ] )
	var reg_r : Dictionary = reg.duplicate()
	reg_r.ra_direction = 1
	var u_c : float = StarSkyMath.uv_from_equatorial( 100.0, 0.0, reg_r ).x
	var u_d : float = StarSkyMath.uv_from_equatorial( 110.0, 0.0, reg_r ).x
	_check( "ra_direction +1: +RA moves RIGHT", _near( fposmod( u_d - u_c, 1.0 ), 10.0 / 360.0, 1e-6 ), "%.6f -> %.6f" % [ u_c, u_d ] )
	var reg_d : Dictionary = reg.duplicate()
	reg_d.north_up = false
	_check( "north_up false: dec +90 -> v 1", _near( StarSkyMath.uv_from_equatorial( 0.0, 90.0, reg_d ).y, 1.0, 1e-9 ) )
	var reg_o : Dictionary = reg.duplicate()
	reg_o.ra_deg_at_u0 = 180.0
	_check( "ra_deg_at_u0 shifts the seam", _near( StarSkyMath.uv_from_equatorial( 180.0, 0.0, reg_o ).x, 0.0, 1e-9 ) )
	# round trip over every catalog star under all four (direction, north_up) combos
	var worst : float = 0.0
	for dirn in [ -1, 1 ] :
		for nu in [ true, false ] :
			var r : Dictionary = reg.duplicate()
			r.ra_direction = dirn
			r.north_up = nu
			r.ra_deg_at_u0 = 33.0
			for key in STARS.keys() :
				var st : Dictionary = STARS[ key ]
				var uv : Vector2 = StarSkyMath.uv_from_equatorial( st.ra, st.dec, r )
				var eq : Dictionary = StarSkyMath.equatorial_from_uv( uv, r )
				worst = maxf( worst, maxf( absf( fposmod( float( eq.ra ) - st.ra + 180.0, 360.0 ) - 180.0 ), absf( float( eq.dec ) - st.dec ) ) )
	_check( "uv round trip (4 conventions × 12 stars)", worst < 1e-4, "%.10f deg" % worst )
	var px : Vector2 = StarSkyMath.pixel_from_equatorial( STARS.polaris.ra, STARS.polaris.dec, reg, 8192, 4096 )
	_check( "Polaris lands ~16.7 px below the top row at 8k", _near( px.y, ( 90.0 - 89.264 ) / 180.0 * 4096.0, 0.01 ), "%.3f" % px.y )
	# sidecar parsing
	var parsed : Dictionary = StarSkyMath.registration_from_dict( {
		"ra_deg_at_u0": 372.5, "ra_direction": 1.0, "north_up": false, "epoch": "J2000",
		"width": 8192, "height": 4096, "registration": { "max_residual_px": 2.5 } } )
	_check( "sidecar: ra0 wrapped", _near( float( parsed.ra_deg_at_u0 ), 12.5, 1e-9 ) )
	_check( "sidecar: direction/north_up/residual", int( parsed.ra_direction ) == 1 and not bool( parsed.north_up ) and _near( float( parsed.residual_px ), 2.5, 1e-9 ) and bool( parsed.sidecar_found ) )
	_check( "sidecar path derivation", StarSkyMath.sidecar_path_for( "res://assets/sky/starmap_equirect_8k.png" ) == "res://assets/sky/starmap_equirect_8k.json" )
	_check( "missing sidecar -> defaults, not found", not bool( StarSkyMath.load_registration( "res://definitely_missing_starmap.png" ).sidecar_found ) )
	_check( "summary mentions the assumption when no sidecar", StarSkyMath.registration_summary( reg ).begins_with( "no sidecar" ) )


# ==================== SHADER MIRROR ====================

func _test_shader_mirror() -> void :
	# For every star, the shader's world-direction -> UV path (mirrored line for
	# line in StarSkyMath.shader_uv_for_direction) must land on the same texel
	# as the pure RA/Dec -> UV mapping. The direction is produced by the LEGACY
	# alt/az path on purpose, so this also exercises basis-vs-legacy again in
	# UV space.
	for dirn in [ -1, 1 ] :
		for nu in [ true, false ] :
			var reg : Dictionary = StarSkyMath.default_registration()
			reg.ra_direction = dirn
			reg.north_up = nu
			reg.ra_deg_at_u0 = 45.0
			var worst : float = 0.0
			for lat in [ LAT_BB, LAT_PERTH, 0.0 ] :
				var basis : Dictionary = StarSkyMath.equatorial_basis( lat )
				for lst in [ 0.0, 77.7, 181.0, 300.0 ] :
					for key in STARS.keys() :
						var st : Dictionary = STARS[ key ]
						var h : Dictionary = StarSkyMath.equatorial_to_horizontal( st.ra, st.dec, lst, lat )
						var dir : Vector3 = StarSkyMath.horizontal_to_direction( h.altitude, h.azimuth )
						var uv_shader : Vector2 = StarSkyMath.shader_uv_for_direction( dir, basis, lst, reg )
						var uv_pure : Vector2 = StarSkyMath.uv_from_equatorial( st.ra, st.dec, reg )
						var du : float = absf( fposmod( uv_shader.x - uv_pure.x + 0.5, 1.0 ) - 0.5 )
						var dv : float = absf( uv_shader.y - uv_pure.y )
						worst = maxf( worst, maxf( du, dv ) )
			_check( "shader mirror == pure UV (dir %d, north_up %s)" % [ dirn, str( nu ) ], worst < 1e-5, "%.10f" % worst )


# ==================== TIMEZONE (one sky for sun AND stars) ====================

func _test_timezone() -> void :
	var clk := CelestialClock.new()
	clk.latitude = LAT_BB
	clk.longitude = LON_BB
	clk.auto_dst = true
	clk.year = 2026
	clk.month = 1
	clk.day = 15
	clk.day_time = 22.0
	_check( "zone meridian rounds to -120 at Bombay Beach", _near( clk.zone_meridian_deg(), -120.0, 1e-9 ), str( clk.zone_meridian_deg() ) )
	_check( "zone offset -8 in January", _near( clk.zone_offset_hours( 2026, 1, 15, 22.0 ), -8.0, 1e-9 ) )
	var jd : float = clk.get_julian_day_utc()
	var want : float = SolarEclipse.calendar_jd_utc( 2026, 1, 16, 6.0 )
	_check( "JD(UTC) = local 22:00 + 8h", _near( jd, want, 1e-9 ), "%.9f vs %.9f" % [ jd, want ] )
	_check( "get_julian_day() is UTC too", _near( clk.get_julian_day(), want, 1e-9 ) )
	_check( "zone offset -7 under DST", _near( clk.zone_offset_hours( 2026, 7, 15, 12.0 ), -7.0, 1e-9 ) )
	clk.month = 7
	clk.day_time = 12.0
	_check( "JD(UTC) under DST = local 12:00 + 7h", _near( clk.get_julian_day_utc(), SolarEclipse.calendar_jd_utc( 2026, 7, 15, 19.0 ), 1e-9 ) )
	# Perth: 115.86 / 15 = 7.72 -> +8 (its real zone)
	var pc := CelestialClock.new()
	pc.latitude = LAT_PERTH
	pc.longitude = LON_PERTH
	pc.auto_dst = true
	pc.year = 2026
	pc.month = 1
	pc.day = 15
	pc.day_time = 22.0
	_check( "Perth zone offset +8", _near( pc.zone_offset_hours( 2026, 1, 15, 22.0 ), 8.0, 1e-9 ) )
	_check( "Perth JD(UTC) = local 22:00 - 8h", _near( pc.get_julian_day_utc(), SolarEclipse.calendar_jd_utc( 2026, 1, 15, 14.0 ), 1e-9 ) )
	# Half-meridian: GDScript round() is half-away-from-zero. Pin it so a change is deliberate.
	var hc := CelestialClock.new()
	hc.longitude = -112.5
	_check( "lon -112.5 rounds to meridian -120 (half away from zero)", _near( hc.zone_meridian_deg(), -120.0, 1e-9 ), str( hc.zone_meridian_deg() ) )
	# ONE SKY: the DirectionalLight sun (zone-time path) and Meeus SPA at the
	# clock's own UTC must agree. Before the unification these differed by the
	# (longitude - meridian)/15 h = 17 min -> ~4° in hour angle.
	clk.month = 1
	clk.day = 15
	clk.day_time = 10.0
	var sun_clock : Vector3 = clk.get_sun_direction()
	var spa : Dictionary = SolarPosition.get_position( LAT_BB, LON_BB, clk.get_julian_day_utc() )
	var sun_spa : Vector3 = SolarPosition.direction_from_horizon( float( spa.azimuth_deg ), float( spa.elevation_deg ) )
	var ang : float = sun_clock.angle_to( sun_spa ) * 180.0 / PI
	_check( "one sky: clock sun == SPA sun at the clock's UTC", ang < 0.6, "%.3f deg apart" % ang )
	# The stars share it: LST from the clock's UTC puts the sun's RA on the meridian at solar noon.
	var noon_clock : float = clk.solar_time_to_clock_time( 12.0 )
	clk.day_time = noon_clock
	var lst_noon : float = clk.get_local_sidereal_time( clk.get_julian_day_utc() )
	var spa_noon : Dictionary = SolarPosition.get_position( LAT_BB, LON_BB, clk.get_julian_day_utc() )
	_check( "one sky: SPA sun on the meridian at clock solar noon", _ang_near( float( spa_noon.azimuth_deg ), 180.0, 0.6 ),
		"az %.3f at clock %.3f (LST %.2f)" % [ float( spa_noon.azimuth_deg ), noon_clock, lst_noon ] )


# ==================== PLANET PATHS — STARS FRAME (analemma mode) ====================

## The analemma "Stars" planet paths are meshed ONCE in equatorial coordinates
## and turned with the sky by a node basis (StarSkyMath.equatorial_to_world_basis)
## — that basis must be exactly direction_from_equatorial, or the paths slide
## off the stars they crossed. And the loops they draw must be the REAL ones:
## the station dates (where geocentric ecliptic longitude stops and reverses)
## are pinned against almanac values, which is the whole point of the frame.
func _test_planet_star_frame() -> void :
	var worst : float = 0.0
	for lat in [ -65.0, -31.95, 0.0, LAT_BB, 89.0 ] :
		for lst in [ 0.0, 47.3, 181.0, 300.5 ] :
			var basis : Basis = StarSkyMath.equatorial_to_world_basis( lst, lat )
			for ra in [ 0.0, 93.0, 200.0, 333.0 ] :
				for dec in [ -80.0, -20.0, 0.0, 45.0, 88.0 ] :
					var a : Vector3 = basis * StarSkyMath.equatorial_vector( ra, dec )
					var b : Vector3 = StarSkyMath.direction_from_equatorial( ra, dec, lst, lat )
					worst = maxf( worst, a.distance_to( b ) )
	_check( "star-frame basis == direction_from_equatorial", worst < 1e-5, "worst " + str( worst ) )
	var bb : Basis = StarSkyMath.equatorial_to_world_basis( 123.4, LAT_BB )
	_check( "star-frame basis is a pure rotation",
		( bb * bb.transposed() ).is_equal_approx( Basis.IDENTITY ) and _near( bb.determinant(), 1.0, 1e-5 ),
		"det %.6f" % bb.determinant() )

	# Almanac stations (geocentric ecliptic longitude, UT dates, 2024–25).
	# Measured: every station within 0.5 d. Tolerance ±1.5 d because the mean
	# Keplerian elements are arcminute-accurate, and at a station the longitude
	# is flat, so an arcminute of error moves the DATE by roughly a day.
	var ps : Node = load( "res://core/astronomy/planets.gd" ).new()
	var stations := [
		[ "mars",    _jd( 2024, 12, 7 ),  _jd( 2025, 2, 24 ) ],
		[ "jupiter", _jd( 2024, 10, 9 ),  _jd( 2025, 2, 4 ) ],
		[ "saturn",  _jd( 2025, 7, 13 ),  _jd( 2025, 11, 28 ) ],
		[ "venus",   _jd( 2025, 3, 2 ),   _jd( 2025, 4, 13 ) ],
		[ "mercury", _jd( 2025, 3, 15 ),  _jd( 2025, 4, 7 ) ],
	]
	for st in stations :
		var pname : String = st[ 0 ]
		var found : Array = _stations( ps, pname, float( st[ 1 ] ) - 20.0, float( st[ 2 ] ) + 20.0 )
		var ok : bool = found.size() == 2 \
			and absf( float( found[ 0 ] ) - float( st[ 1 ] ) ) <= 1.5 \
			and absf( float( found[ 1 ] ) - float( st[ 2 ] ) ) <= 1.5
		var detail : String = "found %d stations" % found.size()
		if found.size() == 2 :
			detail = "retrograde start %.1f d, end %.1f d vs almanac" % [
				float( found[ 0 ] ) - float( st[ 1 ] ), float( found[ 1 ] ) - float( st[ 2 ] ) ]
		_check( "%s retrograde loop matches the almanac" % pname, ok, detail )
	ps.free()


## Geocentric ecliptic longitude (deg) of a planet at `jd` from PlanetSystem's
## own heliocentric solve — the quantity almanac station dates are quoted in.
func _geo_lon( ps: Node, pname: String, jd: float ) -> float :
	var p : Dictionary = ps.call( "get_heliocentric_coords", pname, jd )
	var e : Dictionary = ps.call( "get_heliocentric_coords", "earth", jd )
	return rad_to_deg( atan2( float( p.y ) - float( e.y ), float( p.x ) - float( e.x ) ) )


## Julian days (0.25 d resolution) where the longitude rate changes sign.
func _stations( ps: Node, pname: String, jd0: float, jd1: float ) -> Array :
	var out : Array = []
	var step : float = 0.25
	var prev_rate : float = NAN
	var jd : float = jd0
	while jd < jd1 :
		var rate : float = wrapf( _geo_lon( ps, pname, jd + step ) - _geo_lon( ps, pname, jd ), -180.0, 180.0 )
		if not is_nan( prev_rate ) and signf( rate ) != signf( prev_rate ) :
			out.append( jd )
		prev_rate = rate
		jd += step
	return out


## Julian day at 0h UT of a Gregorian date (Meeus 7.1).
func _jd( y: int, m: int, d: int ) -> float :
	if m <= 2 :
		y -= 1
		m += 12
	var a : int = y / 100
	var b : int = 2 - a + a / 4
	return floor( 365.25 * ( y + 4716 ) ) + floor( 30.6001 * ( m + 1 ) ) + d + b - 1524.5


# ==================== SHIPPED ASSET ====================

func _test_asset() -> void :
	var gpath : String = ProjectSettings.globalize_path( STARMAP_PATH )
	var exists : bool = FileAccess.file_exists( STARMAP_PATH )
	_check( "star map asset present", exists, STARMAP_PATH + " — run tools/starmap_prepare.py on a Stellarium plate-carrée export" )
	var reg : Dictionary = StarSkyMath.load_registration( STARMAP_PATH )
	_check( "star map sidecar present", bool( reg.sidecar_found ), StarSkyMath.sidecar_path_for( STARMAP_PATH ) )
	_check( "sidecar residual <= 8 px", bool( reg.sidecar_found ) and not is_nan( float( reg.residual_px ) ) and float( reg.residual_px ) <= 8.0, str( reg.residual_px ) )
	_check( "sidecar direction well-formed", int( reg.ra_direction ) == -1 or int( reg.ra_direction ) == 1 )
	if not exists :
		_checks += 4
		_fails += 4
		push_error( "FAIL: star map image checks skipped — asset missing" )
		return
	# NOT load("res://…"): under --script that hands back the VRAM-compressed
	# .ctex and get_image() would need a CPU BC7 decode. Read the PNG itself.
	var img := Image.load_from_file( gpath )
	_check( "star map decodes", img != null and not img.is_empty() )
	if img == null or img.is_empty() :
		_checks += 3
		_fails += 3
		return
	var w : int = img.get_width()
	var h : int = img.get_height()
	_check( "star map is 2:1 and >= 4096 wide", w == 2 * h and w >= 4096, "%dx%d" % [ w, h ] )
	_check( "sidecar dims match the image", int( reg.width ) == w and int( reg.height ) == h, "%dx%d vs %dx%d" % [ int( reg.width ), int( reg.height ), w, h ] )
	var worst_top : float = 0.0
	var worst_bot : float = 0.0
	for x in w :
		worst_top = maxf( worst_top, img.get_pixel( x, 0 ).get_luminance() )
		worst_bot = maxf( worst_bot, img.get_pixel( x, h - 1 ).get_luminance() )
	_check( "pole rows are black (no baked-in GUI)", worst_top <= 0.0 and worst_bot <= 0.0, "top %.4f bottom %.4f" % [ worst_top, worst_bot ] )

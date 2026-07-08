shader_type sky;
render_mode use_quarter_res_pass;

// Originaly based on https://godotshaders.com/shader/stylized-sky-shader-with-clouds/ but there's not much left

group_uniforms sky;
	uniform vec3 day_top_color : source_color = vec3( 0.1, 0.6, 1.0 );
	uniform vec3 day_bottom_color : source_color = vec3( 0.4, 0.8, 1.0 );
	uniform vec3 sunset_top_color : source_color = vec3( 0.52, 0.56, 0.68 );    // Muted grey-blue upper sky
	uniform vec3 sunset_bottom_color : source_color = vec3( 0.92, 0.68, 0.40 ); // Warm amber-orange near horizon
	uniform vec3 night_top_color : source_color = vec3( 0.02, 0.0, 0.04 );
	uniform vec3 night_bottom_color : source_color = vec3( 0.1, 0.0, 0.2 );

group_uniforms horizon;
	uniform vec3 horizon_color : source_color = vec3( 0.0, 0.7, 0.8 );
	uniform float horizon_blur : hint_range( 0.0, 1.0, 0.01 ) = 0.05;

group_uniforms sun; // First DirectionalLight3D will be the sun
	uniform vec3 sun_color : source_color = vec3( 10.0, 8.0, 1.0 );
	uniform vec3 sun_sunset_color : source_color = vec3( 10.0, 0.0, 0.0 );
	uniform vec3 sun_gold_color : source_color = vec3( 10.0, 5.0, 1.2 ); // mid golden-hour disc tint
	uniform float sun_size : hint_range( 0.01, 1.0 ) = 0.2;
	uniform float sun_blur : hint_range( 0.01, 20.0 ) = 10.0;
	// Soft radial corona around the sun disc (the "glow", not a hard disc).
	uniform float sun_glow : hint_range( 0.0, 4.0 ) = 1.4;
	uniform float sun_glow_size : hint_range( 1.0, 30.0 ) = 9.0;
	uniform vec3 sun_glow_color : source_color = vec3( 1.0, 0.75, 0.42 );
	// Broad Mie forward-scatter aureole washing the sky around the sun (sunset drama).
	uniform float sun_aureole : hint_range( 0.0, 3.0 ) = 0.8;
	uniform vec3 sun_aureole_color : source_color = vec3( 1.0, 0.6, 0.32 );

group_uniforms moon; // Second DirectionalLight3D will be the moon
	uniform vec3 moon_color : source_color = vec3( 1.0, 0.95, 0.7 );
	uniform float moon_size : hint_range( 0.01, 1.0 ) = 0.06;
	uniform float moon_blur : hint_range( 0.01, 10.0 ) = 0.1;
	uniform float moon_glow : hint_range( 0.0, 2.0 ) = 0.5;
	uniform vec3 moon_glow_color : source_color = vec3( 0.6, 0.7, 1.0 );
	// 0 = no eclipse, 1 = full solar disc covered (drives totality sky dimming).
	uniform float eclipse_obscuration : hint_range( 0.0, 1.0 ) = 0.0;
	// 1 during total/near-total eclipse — enables photosphere-hidden solar corona.
	uniform float eclipse_totality : hint_range( 0.0, 1.0 ) = 0.0;

group_uniforms clouds;
	// Replaced by noise functions, unncomment if you want to use graphical textures
//	uniform sampler2D clouds_top_texture : filter_linear_mipmap, hint_default_black;
//	uniform sampler2D clouds_middle_texture : filter_linear_mipmap, hint_default_black;
//	uniform sampler2D clouds_bottom_texture : filter_linear_mipmap, hint_default_black;
	uniform vec3 clouds_edge_color : source_color = vec3( 0.8, 0.8, 0.98 );
	uniform vec3 clouds_top_color : source_color = vec3( 1.0, 1.0, 1.00 );
	uniform vec3 clouds_middle_color : source_color = vec3( 0.92, 0.92, 0.98 );
	uniform vec3 clouds_bottom_color : source_color = vec3( 0.83, 0.83, 0.94 );
	uniform float clouds_speed : hint_range( 0.0, 20.0, 0.01 ) = 2.0;
	uniform float clouds_direction : hint_range( -0.5, 0.5, 0.01 ) = 0.2;
	uniform float clouds_scale : hint_range( 0.0, 4.0, 0.01 ) = 1.0;
	uniform float clouds_cutoff : hint_range( 0.0, 1.0, 0.01 ) = 0.3;
	uniform float clouds_fuzziness : hint_range( 0.0, 2.0, 0.01 ) = 0.5;
	// More weight is simply a darker color, usefull for rain/storm
	uniform float clouds_weight : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	uniform float clouds_blur : hint_range( 0.0, 1.0, 0.01 ) = 0.25;
	// Storm / nimbus base tint applied as clouds_weight rises (blue-grey, not flat black).
	uniform vec3 storm_cloud_color : source_color = vec3( 0.16, 0.17, 0.22 );

group_uniforms cirrus; // High wispy streak clouds, independent of the cumulus layer
	uniform float cirrus_amount : hint_range( 0.0, 1.0, 0.01 ) = 0.35;
	uniform float cirrus_scale : hint_range( 0.1, 8.0, 0.01 ) = 2.6;
	uniform float cirrus_speed : hint_range( 0.0, 20.0, 0.01 ) = 1.0;
	uniform float cirrus_stretch : hint_range( 1.0, 16.0, 0.1 ) = 7.0;
	uniform float cirrus_direction : hint_range( -0.5, 0.5, 0.01 ) = 0.2;
	// Previous streak bearing + crossfade blend (0 = fully "prev", 1 = fully
	// "direction"). Driven from GDScript (main._advance_cirrus_direction):
	// large wind-bearing jumps are crossfaded between old/new orientation over
	// real time instead of snapping instantly, since a hard rotation of the
	// whole noise field reads as the entire sky spinning — real cirrus doesn't
	// reorient as a solid sheet, new streaks form while old ones dissipate.
	uniform float cirrus_direction_prev : hint_range( -0.5, 0.5, 0.01 ) = 0.2;
	uniform float cirrus_dir_blend : hint_range( 0.0, 1.0, 0.01 ) = 1.0;
	uniform float cirrus_coverage : hint_range( 0.0, 1.0, 0.01 ) = 0.55; // higher = more sky filled
	uniform vec3 cirrus_color : source_color = vec3( 1.0, 1.0, 1.0 );

group_uniforms rainbow;
	// Primary + secondary bows opposite the sun (antisolar point); driven from SolarUI.
	uniform float rainbow_strength : hint_range( 0.0, 1.0, 0.01 ) = 0.0;

group_uniforms stars;
	// Stars texture - MUST be equirectangular projection with:
	//   - North Celestial Pole (Polaris) at TOP CENTER
	//   - South Celestial Pole at BOTTOM CENTER  
	//   - Right Ascension 0h at horizontal center (or adjust stars_ra_offset)
	// Generate with Stellarium: File > Save Screenshot > Spherical (equirectangular)
	uniform sampler2D stars_texture : filter_linear_mipmap, hint_default_black, repeat_enable;
	uniform float stars_speed : hint_range( 0.0, 20.0, 0.01 ) = 1.0;
	uniform float stars_scale : hint_range(0.5, 2.0, 0.01) = 1.0;
	uniform float stars_opacity : hint_range(0.0, 3.0, 0.01) = 1.0;
	// Manual calibration offset - aligns the HDRI starmap's RA zero point (degrees)
	// This corrects for when the Stellarium export was made
	uniform float stars_north_offset : hint_range( -360.0, 360.0, 0.1 ) = 0.0;
	// Local Sidereal Time in degrees (0-360) - drives star rotation throughout the night
	// This should be updated every frame based on simulation date/time/location
	uniform float stars_lst : hint_range( 0.0, 360.0, 0.1 ) = 0.0;
	// Vertical offset to correct pole alignment (degrees, large range for different projections)
	uniform float stars_declination_offset : hint_range( -180.0, 180.0, 0.1 ) = 0.0;
	// Flip the vertical axis (1.0 = flipped, 0.0 = normal)
	// Use if your starmap has NCP at bottom instead of top
	uniform float stars_flip_vertical : hint_range( 0.0, 1.0, 1.0 ) = 0.0;
	// Flip the horizontal axis (1.0 = flipped, 0.0 = normal)
	// Use if stars move backwards with time
	uniform float stars_flip_horizontal : hint_range( 0.0, 1.0, 1.0 ) = 0.0;
	// Twinkling intensity (atmospheric scintillation)
	uniform float stars_twinkle : hint_range( 0.0, 1.0, 0.01 ) = 0.3;
	// How much stars fade near the horizon (atmospheric extinction)
	uniform float stars_horizon_fade : hint_range( 0.0, 1.0, 0.01 ) = 0.5;

group_uniforms planets;
	// Planet direction vectors (normalized, pointing toward each planet)
	uniform vec3 planet_direction_0 = vec3( 0.0, -1.0, 0.0 ); // Mercury
	uniform vec3 planet_direction_1 = vec3( 0.0, -1.0, 0.0 ); // Venus
	uniform vec3 planet_direction_2 = vec3( 0.0, -1.0, 0.0 ); // Mars
	uniform vec3 planet_direction_3 = vec3( 0.0, -1.0, 0.0 ); // Jupiter
	uniform vec3 planet_direction_4 = vec3( 0.0, -1.0, 0.0 ); // Saturn
	// Planet colors (pre-multiplied by brightness)
	uniform vec3 planet_color_0 : source_color = vec3( 0.85, 0.85, 0.8 );  // Mercury
	uniform vec3 planet_color_1 : source_color = vec3( 1.0, 0.98, 0.9 );   // Venus
	uniform vec3 planet_color_2 : source_color = vec3( 1.0, 0.6, 0.4 );    // Mars
	uniform vec3 planet_color_3 : source_color = vec3( 1.0, 0.95, 0.85 );  // Jupiter
	uniform vec3 planet_color_4 : source_color = vec3( 1.0, 0.93, 0.75 );  // Saturn
	// Planet apparent sizes
	uniform float planet_size_0 : hint_range( 0.001, 0.02 ) = 0.004; // Mercury
	uniform float planet_size_1 : hint_range( 0.001, 0.02 ) = 0.008; // Venus
	uniform float planet_size_2 : hint_range( 0.001, 0.02 ) = 0.005; // Mars
	uniform float planet_size_3 : hint_range( 0.001, 0.02 ) = 0.007; // Jupiter
	uniform float planet_size_4 : hint_range( 0.001, 0.02 ) = 0.006; // Saturn
	// Planet visibility flags (0.0 = hidden, 1.0 = visible)
	uniform float planet_enabled_0 = 0.0;
	uniform float planet_enabled_1 = 0.0;
	uniform float planet_enabled_2 = 0.0;
	uniform float planet_enabled_3 = 0.0;
	uniform float planet_enabled_4 = 0.0;
	// Planet glow intensities (0.0 = no glow, 1.0 = moderate, 2.0 = strong)
	uniform float planet_glow_0 : hint_range( 0.0, 2.0 ) = 0.3;  // Mercury
	uniform float planet_glow_1 : hint_range( 0.0, 2.0 ) = 0.6;  // Venus
	uniform float planet_glow_2 : hint_range( 0.0, 2.0 ) = 0.4;  // Mars
	uniform float planet_glow_3 : hint_range( 0.0, 2.0 ) = 0.5;  // Jupiter
	uniform float planet_glow_4 : hint_range( 0.0, 2.0 ) = 0.35; // Saturn
	// Planet glow colors
	uniform vec3 planet_glow_color_0 : source_color = vec3( 0.9, 0.9, 0.85 );   // Mercury
	uniform vec3 planet_glow_color_1 : source_color = vec3( 1.0, 0.98, 0.85 );  // Venus
	uniform vec3 planet_glow_color_2 : source_color = vec3( 1.0, 0.7, 0.5 );    // Mars
	uniform vec3 planet_glow_color_3 : source_color = vec3( 1.0, 0.95, 0.8 );   // Jupiter
	uniform vec3 planet_glow_color_4 : source_color = vec3( 1.0, 0.9, 0.7 );    // Saturn

group_uniforms reference_stars;
	// Reference star markers for HDRI alignment calibration (toggle with S key)
	// These show where bright stars SHOULD appear based on astronomical calculations
	uniform vec3 ref_star_direction_0 = vec3( 0.0, 1.0, 0.0 );  // Polaris
	uniform vec3 ref_star_direction_1 = vec3( 0.0, 1.0, 0.0 );  // Dubhe
	uniform vec3 ref_star_direction_2 = vec3( 0.0, 1.0, 0.0 );  // Betelgeuse
	uniform vec3 ref_star_direction_3 = vec3( 0.0, 1.0, 0.0 );  // Rigel
	uniform vec3 ref_star_direction_4 = vec3( 0.0, 1.0, 0.0 );  // Sirius
	uniform vec3 ref_star_direction_5 = vec3( 0.0, 1.0, 0.0 );  // Vega
	uniform vec3 ref_star_direction_6 = vec3( 0.0, 1.0, 0.0 );  // Arcturus
	uniform vec3 ref_star_direction_7 = vec3( 0.0, 1.0, 0.0 );  // Capella
	uniform vec3 ref_star_color_0 : source_color = vec3( 0.0, 1.0, 1.0 );  // Cyan for Polaris
	uniform vec3 ref_star_color_1 : source_color = vec3( 0.0, 1.0, 0.8 );
	uniform vec3 ref_star_color_2 : source_color = vec3( 1.0, 0.5, 0.0 );  // Orange for Betelgeuse
	uniform vec3 ref_star_color_3 : source_color = vec3( 0.5, 0.8, 1.0 );
	uniform vec3 ref_star_color_4 : source_color = vec3( 1.0, 1.0, 1.0 );  // White for Sirius
	uniform vec3 ref_star_color_5 : source_color = vec3( 0.8, 0.9, 1.0 );
	uniform vec3 ref_star_color_6 : source_color = vec3( 1.0, 0.8, 0.5 );
	uniform vec3 ref_star_color_7 : source_color = vec3( 1.0, 1.0, 0.8 );
	uniform float ref_star_enabled_0 = 0.0;
	uniform float ref_star_enabled_1 = 0.0;
	uniform float ref_star_enabled_2 = 0.0;
	uniform float ref_star_enabled_3 = 0.0;
	uniform float ref_star_enabled_4 = 0.0;
	uniform float ref_star_enabled_5 = 0.0;
	uniform float ref_star_enabled_6 = 0.0;
	uniform float ref_star_enabled_7 = 0.0;

group_uniforms settings;
	uniform float overwritten_time = 0.0;
	// Dedicated clock for cloud/cirrus noise scroll (main._sky_motion_hours),
	// decoupled from overwritten_time: at high simulation speeds, scrolling the
	// cloud noise exactly in lockstep with the compressed calendar makes the sky
	// whip past unrealistically fast, so this value grows sub-linearly with
	// time_scale instead of 1:1 (see main._sky_motion_rate). Falls back to
	// `time` (below) when unset, e.g. before the first update.
	uniform float cloud_motion_time = 0.0;
	uniform float star_rotation_angle = 0.0;
	uniform float celestial_pole_elevation = 0.0;

////////////////////////////////////////////////////////////////////////////////////////////////////
	// Function for clouds noises. You can replace using "gen_fractal_ping_pong" with a simple texture reading.
	// I was frustrated with the repeating texture that's why I included the algorithm in the code.
	// Source: https://github.com/Auburn/FastNoiseLite/tree/master
	const int PRIME_X = 501125321;
	const int PRIME_Y = 1136930381;
	float lerp( float a, float b, float t )
	{
		return a + t * ( b - a );
	}
	float cubic_lerp( float a, float b, float c, float d, float t )
	{
		float p = d - c - ( a - b );
		return t * t * t * p + t * t * ( a - b - p ) + t * ( c - a ) + b;
	}
	float ping_pong( float t )
	{
		t -= trunc( t * 0.5 ) * 2.0;
		return t < 1.0 ? t : 2.0 - t;
	}
	int hash( int seed, int x_primed, int y_primed )
	{
		return ( seed ^ x_primed ^ y_primed ) * 0x27d4eb2d;
	}
	float val_coord( int seed, int x_primed, int y_primed )
	{
	    int hash = hash( seed, x_primed, y_primed );
	    hash *= hash;
	    hash ^= hash << 19;
	    return float( hash ) * ( 1.0 / 2147483648.0 );
	}
	float single_value_cubic( int seed, float x, float y )
	{
	    int x1 = int( floor( x ));
	    int y1 = int( floor( y ));

	    float xs = x - float( x1 );
	    float ys = y - float( y1 );

	    x1 *= PRIME_X;
	    y1 *= PRIME_Y;
	    int x0 = x1 - PRIME_X;
	    int y0 = y1 - PRIME_Y;
	    int x2 = x1 + PRIME_X;
	    int y2 = y1 + PRIME_Y;
	    int x3 = x1 + ( PRIME_X << 1 );
	    int y3 = y1 + ( PRIME_Y << 1 );

	    return cubic_lerp(
	        cubic_lerp( val_coord( seed, x0, y0 ), val_coord( seed, x1, y0 ), val_coord( seed, x2, y0 ), val_coord( seed, x3, y0 ), xs ),
	        cubic_lerp( val_coord( seed, x0, y1 ), val_coord( seed, x1, y1 ), val_coord( seed, x2, y1 ), val_coord( seed, x3, y1 ), xs ),
	        cubic_lerp( val_coord( seed, x0, y2 ), val_coord( seed, x1, y2 ), val_coord( seed, x2, y2 ), val_coord( seed, x3, y2 ), xs ),
	        cubic_lerp( val_coord( seed, x0, y3 ), val_coord( seed, x1, y3 ), val_coord( seed, x2, y3 ), val_coord( seed, x3, y3 ), xs ),
	    ys ) * ( 1.0 / ( 1.5 * 1.5 ));
	}
	// Params can be change in the same way as in noise settings in Godot
	const float FRACTAL_BOUNDING = 1.0 / 1.375;
	const int OCTAVES = 3;
	const float PING_PONG_STRENGTH = 2.0;
	const float WEIGHTED_STRENGTH = 0.0;
	const float GAIN = 0.5;
	const float LACUNARITY = 2.0;
	float gen_fractal_ping_pong( vec2 pos, int seed, float frequency )
	{
		float x = pos.x * frequency;
		float y = pos.y * frequency;
	    float sum = 0.0;
		float amp = FRACTAL_BOUNDING;
	    for( int i = 0; i < OCTAVES; i++ )
	    {
	        float noise = ping_pong(( single_value_cubic( seed++, x, y ) + 1.0 ) * PING_PONG_STRENGTH );
	        sum += ( noise - 0.5 ) * 2.0 * amp;
	        amp *= lerp( 1.0, noise, WEIGHTED_STRENGTH );
	        x *= LACUNARITY;
	        y *= LACUNARITY;
	        amp *= GAIN;
	    }
	    return sum * 0.5 + 0.5;
	}
	// Lightweight 2-octave value noise for the wispy cirrus layer. Cirrus renders
	// almost all day across the upper sky, so it uses a cheaper noise than the full
	// 3-octave ping-pong fractal above (fewer cubic evaluations per pixel).
	float gen_cirrus_noise( vec2 p )
	{
		float n = single_value_cubic( 51, p.x, p.y );
		n += 0.5 * single_value_cubic( 52, p.x * 2.31 + 11.7, p.y * 2.31 - 4.3 );
		return clamp( n / 1.5 * 0.5 + 0.5, 0.0, 1.0 );
	}
	// Cirrus fractal noise sampled with UVs rotated to a given wind bearing
	// (fraction of a full turn). Called twice per pixel — once for the old
	// bearing, once for the new — so a wind-direction change can crossfade
	// between orientations (see cirrus_dir_blend) instead of visibly rotating
	// the whole streak field.
	float sample_cirrus_noise( vec2 base_uv, float dir_frac, float cloud_time_v )
	{
		float _ang = dir_frac * PI * 2.0;
		float _ca = cos( _ang );
		float _sa = sin( _ang );
		vec2 _uv = vec2( base_uv.x * _ca - base_uv.y * _sa, base_uv.x * _sa + base_uv.y * _ca );
		_uv = vec2( _uv.x, _uv.y * cirrus_stretch ) * cirrus_scale;
		_uv += vec2( cloud_time_v * cirrus_speed * 0.004, 0.0 );
		return gen_cirrus_noise( _uv * 0.55 );
	}
////////////////////////////////////////////////////////////////////////////////////////////////////

// Function needed to calculate the phase of the moon
// Source: https://kelvinvanhoorn.com/2022/03/17/skybox-tutorial-part-1/
float sphere_intersect( vec3 view_dir, vec3 sphere_pos, float radius )
{
    float b = dot( -sphere_pos, view_dir );
    float c = dot( -sphere_pos, -sphere_pos ) - pow( radius, 2 );
    float h = pow( b, 2 ) - c;
    return h < 0.0 ? -1.0 : -b - sqrt( h );
}

void sky()
{
	float time = overwritten_time != 0.0 ? overwritten_time : TIME;
	// Cloud/cirrus noise scroll uses its own (sub-linearly time_scale-damped)
	// clock so fast-forwarding the sim doesn't whip the sky past unrealistically.
	float cloud_time = cloud_motion_time != 0.0 ? cloud_motion_time : time;

	//////////////////// SHARED SOLAR GEOMETRY //////////////////////////////////////////////////////
	// Computed once and reused by the sunset sky, the sun glow/aureole, cirrus and cumulus
	// lighting so the whole dome shares a single, consistent golden-hour direction and warmth.
	float _sun_view_dist = distance( EYEDIR, LIGHT0_DIRECTION );
	// Horizontal bearing toward vs. away from the sun (1 = looking at sun, 0 = looking away).
	float _sun_hz_len = length( LIGHT0_DIRECTION.xz );
	float _eye_hz_len = length( EYEDIR.xz );
	float _toward_sun = 0.5;
	if( _sun_hz_len > 0.01 && _eye_hz_len > 0.01 )
		_toward_sun = dot( EYEDIR.xz / _eye_hz_len, LIGHT0_DIRECTION.xz / _sun_hz_len ) * 0.5 + 0.5;
	// Reddening ramp: 0 when the sun is high, 1 near/below the horizon.
	float _sun_redden = 1.0 - smoothstep( 0.0, 0.32, LIGHT0_DIRECTION.y );
	// Normalized warm tint (LDR) used to tint glows, rims and cloud silver-linings.
	vec3 _sun_warm = mix( vec3( 1.0, 0.92, 0.72 ), vec3( 1.0, 0.55, 0.28 ), _sun_redden );

	//////////////////// SKY ///////////////////////////////////////////////////////////////////////
	float _eyedir_y = abs( sin( EYEDIR.y * PI * 0.5 ));

	// The day color will be our base color
	vec3 _sky_color = mix( day_bottom_color, day_top_color, _eyedir_y );
	_sky_color = mix( _sky_color, vec3( 0.0 ), clamp(( 0.7 - clouds_cutoff ) * clouds_weight, 0.0, 1.0 ));

	float _sunset_amount = clamp( 0.5 - abs( LIGHT0_DIRECTION.y ), 0.0, 0.5 ) * 2.0;
	// Dramatic multi-band twilight gradient — only computed while the sun is near the
	// horizon (skipped entirely at midday/deep night, where _sunset_amount is 0).
	//   • Toward the sun: fiery orange near the horizon → pink/magenta mid → deep blue up high.
	//   • Away from the sun: cooler violet/indigo, so the dome reads directional and real.
	if( _sunset_amount > 0.0 )
	{
		float _sky_h = clamp( EYEDIR.y, 0.0, 1.0 );
		vec3 _fire = mix( vec3( 1.0, 0.42, 0.14 ), vec3( 0.98, 0.40, 0.52 ), smoothstep( 0.0, 0.16, _sky_h ) );
		_fire = mix( _fire, sunset_top_color, smoothstep( 0.14, 0.55, _sky_h ) );
		vec3 _cool_sky = mix( vec3( 0.40, 0.30, 0.52 ), sunset_top_color, smoothstep( 0.0, 0.5, _sky_h ) );
		vec3 _sky_sunset_color = mix( _cool_sky, _fire, smoothstep( 0.15, 0.85, _toward_sun ) );
		// Concentrate the strongest fiery band right around the sun on the horizon.
		float _sunset_focus = clamp( 1.0 - pow( _sun_view_dist, 2.0 ), 0.0, 1.0 );
		_sky_sunset_color = mix( _sky_sunset_color, vec3( 1.0, 0.5, 0.2 ), _sunset_amount * _sunset_focus * 0.6 );
		_sky_color = mix( _sky_color, _sky_sunset_color, _sunset_amount );
	}

	float _night_amount = clamp( -LIGHT0_DIRECTION.y + 0.7, 0.0, 1.0 );
	// Totality / deep partial eclipse: daylight collapses while the sun is still up.
	if( LIGHT0_DIRECTION.y > 0.0 && eclipse_obscuration > 0.05 )
	{
		float _eclipse_night = eclipse_obscuration * ( eclipse_obscuration > 0.92 ? 0.95 : 0.55 );
		_night_amount = max( _night_amount, _eclipse_night );
	}
	vec3 _sky_night_color = mix( night_bottom_color, night_top_color, _eyedir_y );
	_sky_color = mix( _sky_color, _sky_night_color, _night_amount );

	// Final sky color
	COLOR = _sky_color;

	//////////////////// HORIZON ///////////////////////////////////////////////////////////////////
	float _horizon_amount = 0.0;
	if( EYEDIR.y < 0.0 )
	{
		_horizon_amount = clamp( abs( EYEDIR.y ) / horizon_blur, 0.0, 1.0 );
		// Mixing with the color of the night sky to make the horizon darker
		vec3 _horizon_color = mix( horizon_color, _sky_color, _night_amount * 0.9 );
		// And if ther are many dark clouds, we also make the horizon darker
		_horizon_color = mix( _horizon_color, vec3( 0.0 ), ( 1.0 - clouds_cutoff ) * clouds_weight * 0.7 );
		COLOR = mix( COLOR, _horizon_color, _horizon_amount );
	}

	//////////////////// MOON //////////////////////////////////////////////////////////////////////
	float _moon_amount = 0.0;
	float _moon_phase_lit = 0.0; // 0 at new moon, 1 at full moon
	if( LIGHT1_ENABLED )
	{
		_moon_phase_lit = pow( ( 1.0 - dot( LIGHT1_DIRECTION, LIGHT0_DIRECTION ) ) * 0.5, 0.7 );
		// Subtle size increase near the horizon (reduced from 25% to 8%)
		float _moon_size = moon_size + cos( LIGHT1_DIRECTION.y * PI ) * moon_size * 0.08;
		float _moon_distance = distance( EYEDIR, LIGHT1_DIRECTION ) / _moon_size;
		
		// Moon glow effect - soft circular halo around the moon
		if( moon_glow > 0.0 && LIGHT1_DIRECTION.y > -0.1 )
		{
			// Glow extends much further than the moon disk
			float _glow_radius = _moon_size * ( 3.0 + moon_glow * 4.0 );
			float _glow_distance = distance( EYEDIR, LIGHT1_DIRECTION ) / _glow_radius;
			// Soft radial falloff for circular glow (not affected by phase shape)
			float _glow_amount = pow( max( 0.0, 1.0 - _glow_distance ), 2.0 + moon_glow );
			// Apply uniform glow intensity based on overall phase
			_glow_amount *= moon_glow * _moon_phase_lit * ( 1.0 - _horizon_amount );
			// Blend glow color with sky
			COLOR = mix( COLOR, moon_glow_color, _glow_amount * 0.4 );
		}
		
		// Skip the geometric disc at new moon — unlit moon is invisible against the sky.
		if( _moon_phase_lit > 0.01 )
		{
			// Finding moon disc and edge blur
			_moon_amount = clamp(( 1.0 - _moon_distance ) / moon_blur, 0.0, 1.0 );
			if( _moon_amount > 0.0 )
			{
				// Moon illumination depending on the position of the sun
				float _moon_intersect = sphere_intersect( EYEDIR, LIGHT1_DIRECTION, _moon_size );
				vec3 _moon_normal = normalize( LIGHT1_DIRECTION - EYEDIR * _moon_intersect );
				// Sharp terminator line - use smoothstep for crisp shadow edge
				float _raw_n_dot_l = dot( _moon_normal, -LIGHT0_DIRECTION );
				float _moon_n_dot_l = smoothstep( -0.02, 0.08, _raw_n_dot_l );
				// Hiding the moon behind the horizon
				_moon_amount *= 1.0 - _horizon_amount;
				COLOR = mix( COLOR, moon_color, _moon_n_dot_l * _moon_amount );
			}
		}
	}

	//////////////////// SUN ///////////////////////////////////////////////////////////////////////
	float _sun_distance = _sun_view_dist;
	if( LIGHT0_ENABLED )
	{
		// Bigger, softer sun near the horizon (atmospheric swelling)
		float _sun_size = sun_size + cos( LIGHT0_DIRECTION.y * PI ) * sun_size * 0.35;
		// Only a lit moon occludes the sun (new moon must not leave a black disc).
		float _moon_occlude = _moon_amount * smoothstep( 0.04, 0.18, _moon_phase_lit );
		float _cover = max( _moon_occlude, eclipse_obscuration );
		float _sun_visible = ( 1.0 - _horizon_amount ) * ( 1.0 - _cover );

		// === TOTALITY CORONA ===
		// When the photosphere is covered the sky goes dark, but the solar corona remains
		// visible as a pale wispy halo with streamers and a thin chromosphere ring.
		if( eclipse_totality > 0.01 && eclipse_obscuration > 0.75 && LIGHT0_DIRECTION.y > 0.02 )
		{
			float _totality = eclipse_totality * smoothstep( 0.75, 0.90, eclipse_obscuration );
			_totality *= ( 1.0 - _horizon_amount );
			vec3 _sun_ax = normalize( LIGHT0_DIRECTION );
			vec3 _ref_up = abs( _sun_ax.y ) > 0.95 ? vec3( 1.0, 0.0, 0.0 ) : vec3( 0.0, 1.0, 0.0 );
			vec3 _tan = normalize( cross( _ref_up, _sun_ax ) );
			vec3 _bit = cross( _sun_ax, _tan );
			vec3 _to_pix = normalize( EYEDIR );
			float _along_s = dot( _to_pix, _sun_ax );
			vec3 _perp = _to_pix - _sun_ax * _along_s;
			float _perp_len = length( _perp );
			vec3 _perp_n = _perp_len > 1e-5 ? _perp / _perp_len : _tan;
			float _ang = atan( dot( _perp_n, _tan ), dot( _perp_n, _bit ) );
			// Normalized angular distance from sun centre (1 ≈ one disc radius).
			float _r_norm = _sun_view_dist / max( _sun_size, 0.001 );
			// Block the lunar silhouette; corona blooms outside the moon disc.
			float _outside_moon = smoothstep( 0.85, 1.15, _r_norm );
			float _stream = 0.55 + 0.45 * sin( _ang * 3.0 + sin( _ang * 7.0 ) * 0.35 );
			float _wisp = 0.65 + 0.35 * gen_cirrus_noise( vec2( _ang * 1.8, _r_norm * 2.5 ) );
			float _corona_rad = pow( max( 0.0, 1.0 - ( _r_norm - 0.9 ) / 9.0 ), 1.35 );
			_corona_rad *= _outside_moon * _stream * _wisp;
			vec3 _corona_col = mix( vec3( 0.88, 0.92, 1.0 ), vec3( 1.0, 0.96, 0.90 ), 0.25 );
			COLOR += _corona_col * _corona_rad * _totality * 0.42;
			// Chromosphere / Baily's-bead hint — warm thin ring just outside the limb.
			float _beads = smoothstep( 0.92, 1.05, _r_norm ) * ( 1.0 - smoothstep( 1.35, 1.75, _r_norm ) );
			_beads *= 0.82 + 0.18 * sin( _ang * 11.0 );
			COLOR += vec3( 1.0, 0.48, 0.18 ) * _beads * _totality * 0.22;
		}

		// Golden-hour disc color: white-gold when high → gold → deep orange/red at the horizon.
		vec3 _sun_disc_color = mix( sun_color, sun_gold_color, smoothstep( 0.0, 0.55, _sun_redden ) );
		_sun_disc_color = mix( _sun_disc_color, sun_sunset_color, smoothstep( 0.55, 1.0, _sun_redden ) );

		// Broad Mie forward-scatter aureole: a wide warm wash across the sky near the sun.
		// Single pow — cheap — and it's what makes the whole sky around the sun glow, most
		// dramatically at sunset.  Whitish at noon, orange at dusk.
		if( sun_aureole > 0.0 && LIGHT0_DIRECTION.y > -0.12 )
		{
			float _aur = pow( max( 0.0, 1.0 - _sun_view_dist / 1.3 ), 2.5 );
			vec3 _aur_col = mix( vec3( 0.85, 0.88, 0.95 ), sun_aureole_color, _sun_redden );
			_aur *= sun_aureole * ( 0.30 + _sun_redden * 1.5 ) * _sun_visible;
			COLOR += _aur_col * _aur;
		}

		// Soft radial corona hugging the disc — the "glow" instead of a hard bright disc.
		if( sun_glow > 0.0 && LIGHT0_DIRECTION.y > -0.12 )
		{
			float _glow_radius = _sun_size * sun_glow_size;
			float _sg = pow( max( 0.0, 1.0 - _sun_view_dist / _glow_radius ), 2.5 );
			vec3 _glow_col = mix( sun_glow_color, _sun_warm, _sun_redden );
			COLOR = mix( COLOR, _glow_col, clamp( _sg * sun_glow * _sun_visible, 0.0, 1.0 ) );
		}

		// Finding sun disc and edge blur
		float _sun_amount = clamp(( 1.0 - _sun_distance / _sun_size ) / sun_blur, 0.0, 1.0 );
		if( _sun_amount > 0.0 )
		{
			_sun_amount = clamp( _sun_amount * _sun_visible, 0.0, 1.0 );
			vec3 _sun_col = _sun_disc_color;
			// Leveling the "glow" in color
			if( _sun_col.r > 1.0 || _sun_col.g > 1.0 || _sun_col.b > 1.0 )
				_sun_col *= _sun_amount;
			COLOR = mix( COLOR, _sun_col, _sun_amount );
		}
	}

	//////////////////// STARS /////////////////////////////////////////////////////////////////
	// Show stars when sun is below horizon
	if( EYEDIR.y > -0.05 && LIGHT0_DIRECTION.y < 0.0 )
	{
		// Get view direction
		vec3 _view_dir = normalize( EYEDIR );
		
		// The celestial pole axis points toward Polaris (North Celestial Pole)
		// At the equator (lat=0°), NCP is on the northern horizon
		// At lat=33° (Bombay Beach), NCP is 33° above the northern horizon
		// In our coordinate system: +Y is up, -Z is north
		float _pole_elevation = radians( celestial_pole_elevation );
		vec3 _pole_axis = vec3( 0.0, sin( _pole_elevation ), -cos( _pole_elevation ) );
		
		// LST rotation: rotate the view around the celestial pole axis
		// This makes stars appear to rotate around Polaris throughout the night
		// Combined with calibration offset for HDRI alignment
		float _lst_rotation = radians( stars_lst + stars_north_offset );
		
		// Apply horizontal flip to rotation direction if needed
		if( stars_flip_horizontal > 0.5 ) {
			_lst_rotation = -_lst_rotation;
		}
		
		// Rodrigues' rotation formula - rotate view around celestial pole
		float _cos_rot = cos( _lst_rotation );
		float _sin_rot = sin( _lst_rotation );
		vec3 _rotated_view = _view_dir * _cos_rot 
			+ cross( _pole_axis, _view_dir ) * _sin_rot 
			+ _pole_axis * dot( _pole_axis, _view_dir ) * ( 1.0 - _cos_rot );
		
		// Convert rotated view direction to equirectangular UV coordinates
		float _longitude = atan( _rotated_view.x, -_rotated_view.z ); // -PI to PI
		float _latitude = asin( clamp( _rotated_view.y, -1.0, 1.0 ) ); // -PI/2 to PI/2
		
		// Apply vertical offset (Declination calibration for HDRI alignment)
		float _dec_offset_rad = radians( stars_declination_offset );
		_latitude = _latitude + _dec_offset_rad;
		
		// Handle latitude wrapping for large offsets
		float _lon_flip = 0.0;
		if( _latitude > PI * 0.5 ) {
			_latitude = PI - _latitude;
			_lon_flip = PI;
		}
		if( _latitude < -PI * 0.5 ) {
			_latitude = -PI - _latitude;
			_lon_flip = PI;
		}
		_latitude = clamp( _latitude, -PI * 0.5, PI * 0.5 );
		
		// Calculate UV coordinates (no LST here - it's in the 3D rotation)
		float _u = fract( ( _longitude + _lon_flip ) / TAU + 0.5 );
		float _v = _latitude / PI + 0.5;  // 0 = SCP, 0.5 = equator, 1 = NCP
		
		// Apply vertical flip if needed (for starmaps with NCP at bottom)
		if( stars_flip_vertical > 0.5 ) {
			_v = 1.0 - _v;
		}
		
		vec2 _stars_uv = vec2( _u, _v );
		
		// Apply scale (centered on current view, not on texture center)
		_stars_uv = ( _stars_uv - 0.5 ) / stars_scale + 0.5;
		
		// Stars texture - sample the HDRI
		vec3 _stars_color = texture( stars_texture, _stars_uv ).rgb;
		
		// Mask out Stellarium UI artifacts (toolbar icons at top, status bar at bottom)
		// that were baked into the texture during screenshot export
		float _tex_v = fract( _stars_uv.y );
		float _edge_mask = smoothstep( 0.0, 0.06, _tex_v ) * smoothstep( 1.0, 0.94, _tex_v );
		_stars_color *= _edge_mask;
		
		// Clean faint background: remove dim noise/airglow while keeping the Milky Way
		float _star_lum = dot( _stars_color, vec3( 0.299, 0.587, 0.114 ) );
		float _bg_mask = smoothstep( 0.02, 0.06, _star_lum );
		_stars_color *= _bg_mask;
		// Desaturate dim pixels to neutralize any residual color cast;
		// only bright stars retain full natural color
		float _color_keep = smoothstep( 0.10, 0.30, _star_lum );
		_stars_color = mix( vec3( _star_lum * _bg_mask ), _stars_color, _color_keep );
		
		// Pole artifact mitigation - fade stars near celestial poles to hide pinching
		// In equirectangular projection, all pixels at poles converge to a single point
		// causing visible pinching/accordion artifacts
		float _pole_distance = abs( _rotated_view.y );  // 1.0 at poles, 0.0 at equator
		float _pole_fade = smoothstep( 0.995, 0.90, _pole_distance );  // Fade within ~25° of poles
		// Near poles, blend stars with a subtle gradient instead of the distorted texture
		vec3 _pole_replacement = vec3( 0.01, 0.01, 0.015 );  // Very dark blue-ish
		_stars_color = mix( _pole_replacement, _stars_color, _pole_fade );
		
		// Star twinkling effect (atmospheric scintillation)
		// Uses position-based noise that varies over time for natural shimmer
		if( stars_twinkle > 0.0 )
		{
			// Create unique twinkle pattern per viewing direction
			float _twinkle_seed = dot( _view_dir, vec3( 12.9898, 78.233, 45.164 ) );
			float _twinkle_noise = fract( sin( _twinkle_seed * 43758.5453 + time * 3.0 ) * 43758.5453 );
			
			// Secondary slower variation for more organic feel
			float _twinkle_slow = fract( sin( _twinkle_seed * 12345.6789 + time * 0.7 ) * 23456.789 );
			
			// Combine fast and slow variations
			float _twinkle_amount = mix( _twinkle_noise, _twinkle_slow, 0.4 );
			
			// Stars twinkle more near horizon (more atmosphere)
			float _horizon_twinkle_boost = 1.0 + ( 1.0 - smoothstep( 0.0, 0.4, EYEDIR.y ) ) * 1.5;
			
			// Apply twinkle - brighter stars twinkle less noticeably
			float _star_brightness = dot( _stars_color, vec3( 0.299, 0.587, 0.114 ) );
			float _twinkle_strength = stars_twinkle * ( 1.0 - _star_brightness * 0.5 ) * _horizon_twinkle_boost;
			
			_stars_color *= 1.0 + ( _twinkle_amount - 0.5 ) * _twinkle_strength;
		}
		
		// Fade stars based on how dark the sky is (twilight transition)
		// More gradual transition for realistic civil/nautical/astronomical twilight
		float _sun_altitude = -LIGHT0_DIRECTION.y;
		float _twilight_factor = smoothstep( -0.05, 0.25, _sun_altitude );
		_stars_color *= _twilight_factor;
		
		// Atmospheric extinction near horizon
		// Stars appear dimmer near horizon due to more atmosphere
		float _view_altitude = EYEDIR.y;
		float _extinction_start = 0.0;
		float _extinction_end = 0.2 + stars_horizon_fade * 0.3;
		float _horizon_extinction = smoothstep( _extinction_start, _extinction_end, _view_altitude );
		
		// Extra dimming for very low angles (light pollution and thick atmosphere)
		float _low_angle_fade = pow( _horizon_extinction, 1.0 + stars_horizon_fade * 2.0 );
		_stars_color *= _low_angle_fade;
		
		// Hiding stars behind the moon
		_stars_color *= 1.0 - _moon_amount;
		
		// Cloud cover attenuation - clouds block starlight
		// clouds_cutoff: 1.0 = clear sky, 0.0 = fully overcast
		// Stars are blocked more by clouds, especially near horizon where clouds extend
		float _cloud_cover = 1.0 - clouds_cutoff;  // 0 = clear, 1 = overcast
		
		// Near horizon, even partial cloud cover blocks stars (clouds are thicker at low angles)
		float _horizon_cloud_factor = 1.0 - smoothstep( 0.1, 0.5, _view_altitude );
		float _cloud_blocking = _cloud_cover * ( 0.7 + _horizon_cloud_factor * 0.3 );
		
		// Storm darkness makes clouds even more opaque to starlight
		_cloud_blocking += clouds_weight * 0.3;
		_cloud_blocking = clamp( _cloud_blocking, 0.0, 1.0 );
		
		// Apply cloud blocking - exponential falloff for more natural look
		float _star_cloud_transmission = pow( 1.0 - _cloud_blocking, 2.0 );
		_stars_color *= _star_cloud_transmission;
		
		COLOR += _stars_color * stars_opacity;

		//////////////////// PLANETS /////////////////////////////////////////////////////////////
		// Inside the night gate — zero GPU cost while the sun is up (the common case).
		// All 5 planets accumulated into one vec3; single COLOR write per planet type.
		// planet_enabled_N (0.0/1.0) used as a multiplier to avoid per-planet branching.
		// Reuses _twilight_factor, _low_angle_fade, _moon_amount, _star_cloud_transmission
		// already computed above — no extra per-pixel work.
		vec3 _planet_accum = vec3( 0.0 );
		float _planet_fade = _twilight_factor * _low_angle_fade * ( 1.0 - _moon_amount ) * _star_cloud_transmission;

		float _pd = distance( EYEDIR, planet_direction_0 );
		_planet_accum += ( planet_color_0 * smoothstep( planet_size_0, 0.0, _pd )
			+ planet_glow_color_0 * pow( max( 0.0, 1.0 - _pd / ( planet_size_0 * ( 3.0 + planet_glow_0 * 5.0 ) ) ), 2.5 ) * planet_glow_0 * 0.5
			) * planet_enabled_0;
		_pd = distance( EYEDIR, planet_direction_1 );
		_planet_accum += ( planet_color_1 * smoothstep( planet_size_1, 0.0, _pd )
			+ planet_glow_color_1 * pow( max( 0.0, 1.0 - _pd / ( planet_size_1 * ( 3.0 + planet_glow_1 * 5.0 ) ) ), 2.5 ) * planet_glow_1 * 0.5
			) * planet_enabled_1;
		_pd = distance( EYEDIR, planet_direction_2 );
		_planet_accum += ( planet_color_2 * smoothstep( planet_size_2, 0.0, _pd )
			+ planet_glow_color_2 * pow( max( 0.0, 1.0 - _pd / ( planet_size_2 * ( 3.0 + planet_glow_2 * 5.0 ) ) ), 2.5 ) * planet_glow_2 * 0.5
			) * planet_enabled_2;
		_pd = distance( EYEDIR, planet_direction_3 );
		_planet_accum += ( planet_color_3 * smoothstep( planet_size_3, 0.0, _pd )
			+ planet_glow_color_3 * pow( max( 0.0, 1.0 - _pd / ( planet_size_3 * ( 3.0 + planet_glow_3 * 5.0 ) ) ), 2.5 ) * planet_glow_3 * 0.5
			) * planet_enabled_3;
		_pd = distance( EYEDIR, planet_direction_4 );
		_planet_accum += ( planet_color_4 * smoothstep( planet_size_4, 0.0, _pd )
			+ planet_glow_color_4 * pow( max( 0.0, 1.0 - _pd / ( planet_size_4 * ( 3.0 + planet_glow_4 * 5.0 ) ) ), 2.5 ) * planet_glow_4 * 0.5
			) * planet_enabled_4;
		COLOR += _planet_accum * _planet_fade;

		//////////////////// REFERENCE STARS /////////////////////////////////////////////////////
		// Calibration markers toggled by HOME key (star_system.gd / show_reference_stars).
		// Larger fixed-size dots with a distinctive glow — no twilight/cloud fade so they
		// stay readable for alignment work regardless of sky conditions.
		vec3 _ref_accum = vec3( 0.0 );
		float _ref_glow_r = 0.05;
		_pd = distance( EYEDIR, ref_star_direction_0 );
		_ref_accum += ( ref_star_color_0 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_0 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_0;
		_pd = distance( EYEDIR, ref_star_direction_1 );
		_ref_accum += ( ref_star_color_1 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_1 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_1;
		_pd = distance( EYEDIR, ref_star_direction_2 );
		_ref_accum += ( ref_star_color_2 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_2 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_2;
		_pd = distance( EYEDIR, ref_star_direction_3 );
		_ref_accum += ( ref_star_color_3 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_3 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_3;
		_pd = distance( EYEDIR, ref_star_direction_4 );
		_ref_accum += ( ref_star_color_4 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_4 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_4;
		_pd = distance( EYEDIR, ref_star_direction_5 );
		_ref_accum += ( ref_star_color_5 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_5 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_5;
		_pd = distance( EYEDIR, ref_star_direction_6 );
		_ref_accum += ( ref_star_color_6 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_6 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_6;
		_pd = distance( EYEDIR, ref_star_direction_7 );
		_ref_accum += ( ref_star_color_7 * smoothstep( 0.012, 0.0, _pd )
			+ ref_star_color_7 * pow( max( 0.0, 1.0 - _pd / _ref_glow_r ), 3.0 ) * 0.5
			) * ref_star_enabled_7;
		COLOR += _ref_accum * ( 1.0 - _moon_amount );
	}

	//////////////////// RAINBOW /////////////////////////////////////////////////////////////////
	// Descartes minimum-deviation arc (~42°) around the antisolar point; needs sun + rain.
	if( rainbow_strength > 0.01 && LIGHT0_DIRECTION.y > 0.08 && EYEDIR.y > 0.02 )
	{
		vec3 _antisun = normalize( -LIGHT0_DIRECTION );
		float _theta = acos( clamp( dot( EYEDIR, _antisun ), -1.0, 1.0 ) );
		const float _PRIMARY = 0.733038; // 42 deg
		const float _SECONDARY = 0.890118; // 51 deg
		float _prim_band = 1.0 - smoothstep( 0.0, 0.035, abs( _theta - _PRIMARY ) );
		_prim_band *= smoothstep( 0.02, 0.12, EYEDIR.y );
		float _spec_t = clamp( ( _theta - 0.68 ) / 0.10, 0.0, 1.0 );
		vec3 _bow_col = mix( vec3( 1.0, 0.25, 0.08 ), vec3( 0.45, 0.15, 0.95 ), _spec_t );
		COLOR += _bow_col * _prim_band * rainbow_strength * 0.38;
		float _sec_band = 1.0 - smoothstep( 0.0, 0.028, abs( _theta - _SECONDARY ) );
		vec3 _bow2 = mix( vec3( 0.45, 0.15, 0.95 ), vec3( 1.0, 0.25, 0.08 ), _spec_t );
		COLOR += _bow2 * _sec_band * rainbow_strength * 0.07;
	}

	//////////////////// CIRRUS //////////////////////////////////////////////////////////////////
	// High, wispy, streaked clouds rendered independently of the cumulus layer (so they can
	// appear in otherwise-clear skies).  A single stretched-and-rotated fractal makes the thin
	// filament look; they catch sunset color dramatically since they sit high in the atmosphere.
	if( EYEDIR.y > 0.02 && cirrus_amount > 0.01 && LIGHT0_DIRECTION.y > -0.25 )
	{
		vec2 _cir_base = EYEDIR.xz / sqrt( EYEDIR.y );
		// Sample the streak noise at both the previous and current wind bearing and
		// crossfade between them (cirrus_dir_blend) — avoids the whole sky visibly
		// "spinning" when the high-altitude wind direction jumps.
		float _cir_noise_from = sample_cirrus_noise( _cir_base, cirrus_direction_prev, cloud_time );
		float _cir_noise_to = sample_cirrus_noise( _cir_base, cirrus_direction, cloud_time );
		// Coverage widens the accepted band; higher coverage = more of the sky filled.
		float _cir_lo = mix( 0.62, 0.40, cirrus_coverage );
		float _cir_from = smoothstep( _cir_lo, _cir_lo + 0.28, _cir_noise_from );
		float _cir_to = smoothstep( _cir_lo, _cir_lo + 0.28, _cir_noise_to );
		float _cir = mix( _cir_from, _cir_to, clamp( cirrus_dir_blend, 0.0, 1.0 ) ) * cirrus_amount;
		// Fade out toward the horizon and at night.
		_cir *= clamp( ( EYEDIR.y - 0.02 ) / 0.14, 0.0, 1.0 );
		_cir *= 1.0 - _night_amount * 0.92;

		vec3 _cir_col = cirrus_color;
		if( _sunset_amount > 0.0 )
		{
			vec3 _cir_warm = mix( vec3( 1.0, 0.52, 0.32 ), vec3( 1.0, 0.82, 0.5 ), clamp( EYEDIR.y * 2.0, 0.0, 1.0 ) );
			vec3 _cir_cool = vec3( 0.72, 0.6, 0.86 );
			vec3 _cir_sunset = mix( _cir_cool, _cir_warm, _toward_sun );
			_cir_col = mix( cirrus_color, _cir_sunset, clamp( _sunset_amount * 1.3, 0.0, 1.0 ) );
		}
		_cir_col = mix( _cir_col, _sky_color, _night_amount );
		COLOR = mix( COLOR, _cir_col, clamp( _cir, 0.0, 1.0 ) );
	}

	//////////////////// CLOUDS ////////////////////////////////////////////////////////////////
	if( EYEDIR.y > 0.0 && clouds_cutoff < 0.99 )
	{
		// Calculate sky UV for clouds
		vec2 _sky_uv = EYEDIR.xz / sqrt( EYEDIR.y );
		
		// Clouds UV movement direction
		float _clouds_speed = cloud_time * clouds_speed * 0.01;
		float _sin_x = sin( clouds_direction * PI * 2.0 );
		float _cos_y = cos( clouds_direction * PI * 2.0 );
		// I using 3 levels of clouds. Top is the lightes and botom the darkest.
		// The speed of movement (and direction a little) is different for the illusion of the changing shape of the clouds.
		vec2 _clouds_movement = vec2( _sin_x, _cos_y ) * _clouds_speed;
//		float _noise_top = texture( clouds_top_texture, ( _sky_uv + _clouds_movement ) * clouds_scale ).r;
		float _noise_top = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement ) * clouds_scale, 0, 0.5 );
		_clouds_movement = vec2( _sin_x * 0.97, _cos_y * 1.07 ) * _clouds_speed * 0.89;
//		float _noise_middle = texture( clouds_middle_texture, ( _sky_uv + _clouds_movement ) * clouds_scale ).r;
		float _noise_middle = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement ) * clouds_scale, 1, 0.75 );
		_clouds_movement = vec2( _sin_x * 1.01, _cos_y * 0.89 ) * _clouds_speed * 0.79;
//		float _noise_bottom = texture( clouds_bottom_texture, ( _sky_uv + _clouds_movement ) * clouds_scale ).r;
		float _noise_bottom = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement ) * clouds_scale, 2, 1.0 );
		// Smoothstep with the addition of a noise value from a lower level gives a nice, deep result
		_noise_bottom = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_bottom );
		_noise_middle = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_middle + _noise_bottom * 0.2 ) * 1.1;
		_noise_top = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_top + _noise_middle * 0.4 ) * 1.2;
		float _clouds_amount = clamp( _noise_top + _noise_middle + _noise_bottom, 0.0, 1.0 );
		// Fading clouds near the horizon
		_clouds_amount *= clamp( abs( EYEDIR.y ) / clouds_blur, 0.0, 1.0 );

		vec3 _clouds_color = mix( vec3( 0.0 ), clouds_top_color, _noise_top );
		_clouds_color = mix( _clouds_color, clouds_middle_color, _noise_middle );
		_clouds_color = mix( _clouds_color, clouds_bottom_color, _noise_bottom );
		// The edge color gives a nice smooth edge, you can try turning this off if you need sharper edges
		_clouds_color = mix( clouds_edge_color, _clouds_color, _noise_top );
		// The sun passing through the clouds effect
		_clouds_color = mix( _clouds_color, clamp( sun_color, 0.0, 1.0 ), pow( 1.0 - clamp( _sun_distance, 0.0, 1.0 ), 5 ));
		// Silver / gold lining: bright warm rim where a cloud edge is backlit by the sun.
		// Edges have low _noise_top (thin cloud) but high overall amount, and it strengthens
		// toward the sun and near sunset — the classic dramatic backlit-cloud look.
		float _rim = pow( max( 0.0, 1.0 - _sun_distance ), 3.0 ) * ( 1.0 - _noise_top ) * _clouds_amount;
		_clouds_color += _sun_warm * _rim * ( 0.6 + _sun_redden * 1.4 );
		// Directional sunset / sunrise cloud lighting.
		// Real-world golden-hour clouds are lit asymmetrically:
		//   • Sun-facing sides: warm golden-yellow tops, deep orange bases
		//   • Anti-solar sides: indigo-purple bases, blue-lavender tops
		//   • Mid-elevation, anti-solar: pink Belt-of-Venus band
		// All effects scale with _sunset_amount so they're zero at noon/midnight.
		// _toward_sun is the shared horizontal bearing computed once at the top.
		if( _sunset_amount > 0.0 )
		{
			// Height proxy: 0 = near horizon (cloud underside view), 1 = overhead (lit tops).
			float _ch = clamp( EYEDIR.y * 4.0, 0.0, 1.0 );

			// Warm palette (sun-facing): deep orange base → golden yellow lit top
			vec3 _warm = mix( vec3( 0.95, 0.48, 0.14 ), vec3( 1.0, 0.84, 0.30 ), _ch );
			// Cool palette (anti-solar): indigo shadow base → blue-lavender lit top
			vec3 _cool = mix( vec3( 0.34, 0.26, 0.56 ), vec3( 0.64, 0.67, 0.88 ), _ch );
			// Belt-of-Venus pink band: peaks at mid-elevation on the anti-solar side
			float _bov = _ch * ( 1.0 - _ch ) * 4.0 * ( 1.0 - _toward_sun );

			vec3 _sunset_clouds = mix( _cool, _warm, _toward_sun );
			_sunset_clouds = mix( _sunset_clouds, vec3( 0.90, 0.58, 0.72 ), clamp( _bov * 0.55, 0.0, 1.0 ) );

			_clouds_color = mix( _clouds_color, _sunset_clouds, clamp( _sunset_amount * 1.15, 0.0, 1.0 ) );
		}

		// Color depending on the "progress" of the night.
		_clouds_color = mix( _clouds_color, _sky_color, clamp( _night_amount, 0.0, 0.98 ));
		// Storm / nimbus styling: instead of flatly crushing to black, tint toward a heavy
		// blue-grey and darken the undersides for a moody, three-dimensional storm cloud.
		_clouds_color = mix( _clouds_color, storm_cloud_color, clouds_weight * 0.82 );
		_clouds_color *= 1.0 - clouds_weight * 0.35 * ( 1.0 - _noise_top );
		COLOR = mix( COLOR, _clouds_color, _clouds_amount );
	}

}

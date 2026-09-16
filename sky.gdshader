shader_type sky;
render_mode use_quarter_res_pass;

// Originaly based on https://godotshaders.com/shader/stylized-sky-shader-with-clouds/ but there's not much left

group_uniforms sky;
	uniform vec3 day_top_color : source_color = vec3( 0.1, 0.6, 1.0 );
	uniform vec3 day_bottom_color : source_color = vec3( 0.4, 0.8, 1.0 );
	uniform vec3 sunset_top_color : source_color = vec3( 0.52, 0.56, 0.68 );    // Muted grey-blue upper sky
	uniform vec3 sunset_bottom_color : source_color = vec3( 0.92, 0.68, 0.40 ); // Warm amber-orange near horizon
	// A moonless Bortle-1 sky is near-black and slightly BLUE-grey, not purple:
	// zenith ~(0.004, 0.006, 0.012), a shade lighter toward the horizon.
	uniform vec3 night_top_color : source_color = vec3( 0.004, 0.006, 0.012 );
	uniform vec3 night_bottom_color : source_color = vec3( 0.010, 0.014, 0.024 );

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
	uniform vec2 cloud_uv_offset = vec2( 0.0, 0.0 );
	uniform float clouds_scale : hint_range( 0.0, 4.0, 0.01 ) = 1.0;
	uniform float clouds_cutoff : hint_range( 0.0, 1.0, 0.01 ) = 0.3;
	uniform float clouds_fuzziness : hint_range( 0.0, 2.0, 0.01 ) = 0.5;
	// More weight is simply a darker color, usefull for rain/storm
	uniform float clouds_weight : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	uniform float clouds_blur : hint_range( 0.0, 1.0, 0.01 ) = 0.25;
	// Storm / nimbus base tint applied as clouds_weight rises (blue-grey, not flat black).
	uniform vec3 storm_cloud_color : source_color = vec3( 0.16, 0.17, 0.22 );

group_uniforms cirrus; // High wispy streak clouds, independent of the cumulus layer
	uniform vec2 cirrus_uv_offset = vec2( 0.0, 0.0 );
	uniform float cirrus_amount : hint_range( 0.0, 1.0, 0.01 ) = 0.35;
	uniform float cirrus_scale : hint_range( 0.1, 8.0, 0.01 ) = 2.6;
	uniform float cirrus_wave_frequency : hint_range( 0.0, 50.0, 0.1 ) = 15.0;
	uniform float cirrus_wave_intensity : hint_range( 0.0, 1.0, 0.01 ) = 0.5;
	uniform float cirrus_stretch : hint_range( 1.0, 16.0, 0.1 ) = 7.0;
	// Driven by the smoothed current velocity vector to align streaks to wind
	uniform float cirrus_direction : hint_range( -0.5, 0.5, 0.01 ) = 0.2;
	uniform float cirrus_coverage : hint_range( 0.0, 1.0, 0.01 ) = 0.55; // higher = more sky filled
	uniform vec3 cirrus_color : source_color = vec3( 1.0, 1.0, 1.0 );

group_uniforms rainbow;
	// Primary + secondary bows opposite the sun (antisolar point); driven from SolarUI.
	uniform float rainbow_strength : hint_range( 0.0, 1.0, 0.01 ) = 0.0;

group_uniforms hazard; // Extreme weather (wildfire smoke, dust) — see AtmosphereApplier
	// Environment.fog_sky_affect can only blend the FOG colour into the sky, and
	// the fog colour is simultaneously doing duty as the terrain haze — which
	// under smoke must be dark while the sky must be luminous. One colour cannot
	// be both, so the sky gets its own tint here.
	//
	// Applied BEFORE the moon/sun/cloud blocks below, deliberately: the sky
	// gradient is taken over, then the sun disc still draws on top at full
	// strength in its own reddened colour. That combination — luminous orange
	// sky plus a dim red disc — IS the wildfire-smoke image. Mixing over the
	// disc instead washes it out and the scene reads as flat brown fog.
	uniform vec3 hazard_haze_color : source_color = vec3( 0.62, 0.26, 0.10 );
	uniform float hazard_haze : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	// Extra weighting toward the horizon: a smoke layer is optically far thicker
	// along a grazing line of sight than straight up, which is why the horizon
	// goes opaque orange while the zenith stays comparatively clear.
	uniform float hazard_horizon_bias : hint_range( 0.0, 1.0, 0.01 ) = 0.65;

group_uniforms stars;
	// Stars texture — an EQUIRECTANGULAR (plate carrée) all-sky map in the EQUATORIAL
	// frame, exported by tools/stellarium_starmap_export.ssc and cleaned/registered by
	// tools/starmap_prepare.py. Which RA sits at u = 0, which way RA runs across the
	// image and whether the NCP is the top row are NOT assumed here: they come from
	// the sidecar JSON next to the texture and are pushed by StarSystem as the three
	// registration uniforms below.
	// Linear (no mipmap) keeps the point stars sharp — mipmaps were blooming a soft halo.
	uniform sampler2D stars_texture : filter_linear, hint_default_black, repeat_enable;
	// The SAME map through a mipmap sampler: the diffuse Milky Way path reads a
	// genuine box blur off the mip chain (one textureLod tap). filter_linear on
	// stars_texture keeps the star points sharp; this one exists only so the
	// band can be smooth. StarSystem pushes both.
	uniform sampler2D stars_texture_soft : filter_linear_mipmap, hint_default_black, repeat_enable;
	uniform float stars_opacity : hint_range(0.0, 3.0, 0.01) = 1.0;
	// Soft glow mix around stars (0 = sharp point stars, 1 = max halo from blurred sample).
	uniform float stars_glow : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	// Contrast lift for sharp cores (higher = dim texture noise cut harder).
	uniform float stars_contrast : hint_range( 1.0, 4.0, 0.05 ) = 2.2;
	// Luminance below which the map reads as sky background (the prep tool already
	// black-floors the export; this only trims residual airglow). Fades in to 3× this.
	uniform float stars_background_cut : hint_range( 0.0, 0.3, 0.005 ) = 0.04;
	// Classic long-exposure star trails (arcs about the celestial pole).
	uniform float star_trails : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	uniform float star_trail_length : hint_range( 0.0, 1.0, 0.01 ) = 0.35;
	// Local Mean Sidereal Time in degrees (0-360), pushed on every sky tick by StarSystem.
	uniform float stars_lst : hint_range( 0.0, 360.0, 0.1 ) = 0.0;
	// Equatorial basis in WORLD space at the observer's latitude φ
	// (StarSkyMath.equatorial_basis; world north = −Z, east = +X, up = +Y):
	//   pole     = north celestial pole              = (0,  sin φ, −cos φ)
	//   meridian = equator point on the meridian     = (0,  cos φ,  sin φ)   (due south)
	//   east     = east point of the equator         = (1,  0,      0)
	// Three vectors rather than a mat3 so there is no Basis column/row ambiguity.
	// The OLD block rotated the view about the pole and then read the texture latitude
	// off the rotated WORLD vector's y — the zenith as the texture pole — which is only
	// right at latitude 90°. Do not reintroduce that; the basis is the whole fix.
	uniform vec3 stars_axis_pole = vec3( 0.0, 1.0, 0.0 );
	uniform vec3 stars_axis_meridian = vec3( 0.0, 0.0, 1.0 );
	uniform vec3 stars_axis_east = vec3( 1.0, 0.0, 0.0 );
	// Texture registration (from the sidecar): RA at u = 0 (deg); RA direction across the
	// image (−1 = RA increases LEFTWARD, the inside-the-sphere convention; +1 = rightward);
	// 1.0 when the north celestial pole is the TOP row.
	uniform float stars_ra_at_u0_deg : hint_range( 0.0, 360.0, 0.01 ) = 0.0;
	uniform float stars_ra_direction : hint_range( -1.0, 1.0, 2.0 ) = -1.0;
	uniform float stars_north_up : hint_range( 0.0, 1.0, 1.0 ) = 1.0;
	// Twinkling intensity (atmospheric scintillation)
	uniform float stars_twinkle : hint_range( 0.0, 1.0, 0.01 ) = 0.3;
	// How much stars fade near the horizon (atmospheric extinction)
	uniform float stars_horizon_fade : hint_range( 0.0, 1.0, 0.01 ) = 0.5;

	// --- Star look ---------------------------------------------------------------
	// Texel size of stars_texture (1/w, 1/h). Every neighbour tap below is in
	// TEXELS so an 8k and a 16k map render the same look; pushed by StarSystem.
	uniform vec2 stars_texel = vec2( 0.0001220703125, 0.000244140625 ); // 1/8192, 1/4096
	// −1 = erode every star disc by one texel (smaller, sharper points),
	// +1 = dilate. 0 = the map as exported.
	uniform float stars_point_size : hint_range( -1.0, 1.0, 0.05 ) = 0.0;
	// Colour saturation of the star cores. The export clips a bright star's
	// centre to white; its colour survives in the FRINGE, so the tint is read
	// off the four neighbour taps and re-applied to the core's luminance.
	uniform float stars_saturation : hint_range( 0.0, 3.0, 0.05 ) = 1.5;
	// How strongly a bright sky (moonlight, light pollution) washes out the
	// faint stars and the Milky Way: raises the background cut by this × the
	// night-sky luminance. 0 = stars ignore the sky (the old behaviour).
	uniform float stars_wash : hint_range( 0.0, 1.0, 0.05 ) = 0.7;
	// The Milky Way is the DIFFUSE part of the map (luminance below the star
	// cores): its own gain and colour saturation, so it can be lifted out of the
	// black without turning every star into a blob.
	uniform float milkyway_gain : hint_range( 0.0, 4.0, 0.05 ) = 1.3;
	uniform float milkyway_saturation : hint_range( 0.0, 3.0, 0.05 ) = 1.2;
	// Tint multiplied into the diffuse band (the export's Milky Way is blue-grey;
	// a long exposure reads warm-white with brown dust lanes).
	uniform vec3 milkyway_tint : source_color = vec3( 1.0, 0.94, 0.88 );

group_uniforms night; // The dark sky itself — see the NIGHT block in sky()
	// Airglow: the faint luminous band a truly dark sky shows 10–25° above the
	// horizon (upper-atmosphere chemiluminescence; the 557.7 nm oxygen line
	// makes it read green on a camera). Strength 0 = none.
	uniform vec3 airglow_color : source_color = vec3( 0.16, 0.30, 0.22 );
	uniform float airglow_strength : hint_range( 0.0, 1.0, 0.01 ) = 0.25;
	// Light pollution: a warm sodium/LED dome brightening steeply toward the
	// horizon and lifting the whole sky a little. 0 = Bortle-1 wilderness.
	uniform vec3 light_pollution_color : source_color = vec3( 0.95, 0.62, 0.35 );
	uniform float light_pollution : hint_range( 0.0, 1.0, 0.01 ) = 0.0;
	// Moonlit sky: a moon-blue wash scaled by phase and altitude. A full moon
	// brightens the sky roughly tenfold over a moonless night and hides the
	// faint stars — which is what stars_wash turns into.
	uniform float moon_sky_glow : hint_range( 0.0, 2.0, 0.05 ) = 1.0;
	// Twilight drama: scales the horizon fire band, the sun aureole and glow
	// near the horizon, and the Belt of Venus opposite the sun. 1 = natural.
	uniform float twilight_drama : hint_range( 0.0, 2.0, 0.05 ) = 1.2;
	// Scales the solar-depression ramp of daylight_fraction() (1 = exp(−0.25/°)).
	uniform float twilight_length : hint_range( 0.25, 3.0, 0.05 ) = 1.0;

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
	// Cloud motion uses explicit UV offsets in the groups above.

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
	// Cirrus fractal noise sampled with UVs rotated to the smoothed wind bearing.
	// Since we accumulate cirrus_uv_offset in world space, we must rotate the
	// offset into the streak's local space to avoid sliding sideways.
	float sample_cirrus_noise( vec2 base_uv )
	{
		float _ang = cirrus_direction * PI * 2.0;
		float _ca = cos( _ang );
		float _sa = sin( _ang );
		// Rotate the base UV to align streaks with wind
		vec2 _uv = vec2( base_uv.x * _ca - base_uv.y * _sa, base_uv.x * _sa + base_uv.y * _ca );
		
		// Rotate the world-space offset into the same local space so scrolling 
		// exactly follows the streak orientation
		vec2 _local_offset = vec2( cirrus_uv_offset.x * _ca - cirrus_uv_offset.y * _sa, cirrus_uv_offset.x * _sa + cirrus_uv_offset.y * _ca );
		
		_uv = vec2( _uv.x, _uv.y * cirrus_stretch ) * cirrus_scale;
		_uv += _local_offset * 1.5; // Apply offset
		
		float n = gen_cirrus_noise( _uv * 0.55 );
		if( cirrus_wave_intensity > 0.01 )
		{
			// Mackerel sky gravity waves: banding perpendicular to the streak (wind) direction.
			float wave = sin( _uv.y * cirrus_wave_frequency ) * 0.5 + 0.5;
			n = mix( n, n * wave, cirrus_wave_intensity );
		}
		return n;
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

// ROYGBIV along bow thickness: t=0 outer/red, t=1 inner/violet (Descartes min-deviation).
vec3 _rainbow_spectrum( float t )
{
	t = clamp( t, 0.0, 1.0 );
	vec3 _r = vec3( 1.00, 0.18, 0.05 );
	vec3 _o = vec3( 1.00, 0.48, 0.04 );
	vec3 _y = vec3( 1.00, 0.90, 0.12 );
	vec3 _g = vec3( 0.18, 0.82, 0.22 );
	vec3 _c = vec3( 0.12, 0.72, 0.92 );
	vec3 _b = vec3( 0.18, 0.38, 0.95 );
	vec3 _v = vec3( 0.52, 0.14, 0.82 );
	if( t < 0.17 ) return mix( _r, _o, t / 0.17 );
	if( t < 0.33 ) return mix( _o, _y, ( t - 0.17 ) / 0.16 );
	if( t < 0.50 ) return mix( _y, _g, ( t - 0.33 ) / 0.17 );
	if( t < 0.67 ) return mix( _g, _c, ( t - 0.50 ) / 0.17 );
	if( t < 0.83 ) return mix( _c, _b, ( t - 0.67 ) / 0.16 );
	return mix( _b, _v, ( t - 0.83 ) / 0.17 );
}

// Diffuse skylight relative to full day, as a function of sin(solar altitude).
// A line-for-line MIRROR of DaylightModel.sky_light (core/env/daylight_model.gd),
// which main.gd feeds to the ambient, fog and glow — edit both or the ground
// and the sky darken on different curves. Above the horizon the sky climbs
// from 55 % at sunrise to full by 15°; below it, exp(−0.25 · depression°)
// per twilight_length with a soft cut at the end of astronomical twilight.
float daylight_fraction( float sin_alt, float tw_len )
{
	if( sin_alt >= 0.0 )
		return mix( 0.55, 1.0, smoothstep( 0.0, 0.26, sin_alt ) );
	float tl = max( tw_len, 0.05 );
	float d = degrees( asin( clamp( -sin_alt, 0.0, 1.0 ) ) );
	return 0.55 * exp( -0.25 / tl * d ) * ( 1.0 - smoothstep( 15.0 * tl, 21.0 * tl, d ) );
}

void sky()
{
	float time = overwritten_time != 0.0 ? overwritten_time : TIME;

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
	float _sun_alt = LIGHT0_DIRECTION.y;   // sin( solar altitude )
	float _daylight = daylight_fraction( _sun_alt, twilight_length );
	// Moon phase: needed by the NIGHT block here and by the MOON block later.
	float _moon_phase_lit = 0.0; // 0 at new moon, 1 at full moon
	if( LIGHT1_ENABLED )
		_moon_phase_lit = pow( ( 1.0 - dot( LIGHT1_DIRECTION, LIGHT0_DIRECTION ) ) * 0.5, 0.7 );

	// The day color will be our base color — the blue itself is dimmer at
	// sunrise than at noon (55 % → 100 % over the first 15° of altitude).
	vec3 _sky_color = mix( day_bottom_color, day_top_color, _eyedir_y ) * max( _daylight, 0.55 );
	_sky_color = mix( _sky_color, vec3( 0.0 ), clamp(( 0.7 - clouds_cutoff ) * clouds_weight, 0.0, 1.0 ));

	//////////////////// TWILIGHT //////////////////////////////////////////////////////////////////
	// A solar-DEPRESSION model. In sin(altitude): 0.105 = 6° (civil twilight
	// ends), 0.208 = 12° (nautical), 0.309 = 18° (astronomical night). The old
	// form ran one symmetric sunset tint from 30° ABOVE the horizon to 30° BELOW
	// it, so the afternoon sky went pale hours early and the night sky stayed
	// violet until the sun was 30° down; and "night" was already 70 % black with
	// the sun still ON the horizon, which is why sunsets rendered dim.
	//
	// _sunset_amount: 1 on the horizon, gone 15° above (golden hour) and 14°
	// below — the palette's BRIGHTNESS below the horizon is the night mix
	// (_daylight), so the last of the glow fades out rather than cutting.
	float _sunset_amount = ( _sun_alt >= 0.0 )
		? 1.0 - smoothstep( 0.0, 0.26, _sun_alt )
		: 1.0 - smoothstep( 0.0, 0.24, -_sun_alt );
	_sunset_amount = _sunset_amount * _sunset_amount * ( 3.0 - 2.0 * _sunset_amount );
	if( _sunset_amount > 0.0 )
	{
		float _sky_h = clamp( EYEDIR.y, 0.0, 1.0 );
		float _drama = twilight_drama;
		// Sun side: fire on the horizon -> salmon -> the twilight top colour above.
		vec3 _fire_lo = mix( vec3( 1.0, 0.50, 0.16 ), vec3( 1.0, 0.34, 0.08 ), clamp( _drama - 1.0, 0.0, 1.0 ) )
			* ( 1.0 + 0.35 * _drama ); // pushed past 1.0 so the bloom carries the glare
		vec3 _fire = mix( _fire_lo, vec3( 0.98, 0.58, 0.46 ), smoothstep( 0.0, 0.12, _sky_h ) );
		_fire = mix( _fire, sunset_top_color, smoothstep( 0.10, 0.45, _sky_h ) );
		// Anti-sun side: the Earth's shadow (blue-grey) with the Belt of Venus
		// (pink) on top of it 2–8° up, then the twilight top colour.
		vec3 _shadow = vec3( 0.30, 0.34, 0.50 );
		vec3 _venus = vec3( 0.86, 0.56, 0.62 );
		float _belt = smoothstep( 0.02, 0.09, _sky_h ) * ( 1.0 - smoothstep( 0.11, 0.30, _sky_h ) );
		vec3 _anti = mix( _shadow, _venus, _belt * clamp( 0.7 * _drama, 0.0, 1.0 ) );
		_anti = mix( _anti, sunset_top_color, smoothstep( 0.15, 0.55, _sky_h ) );
		vec3 _tw = mix( _anti, _fire, smoothstep( 0.2, 0.85, _toward_sun ) );
		// Horizon glare band around the sun's bearing — the brightest part of the show.
		float _focus = clamp( 1.0 - pow( _sun_view_dist / 1.25, 2.0 ), 0.0, 1.0 );
		_tw = mix( _tw, vec3( 1.0, 0.62, 0.26 ), clamp( _sunset_amount * _focus * 0.55 * _drama, 0.0, 1.0 ) );
		_sky_color = mix( _sky_color, _tw, _sunset_amount );
	}

	//////////////////// NIGHT /////////////////////////////////////////////////////////////////////
	// Night amount = 1 − the twilight envelope: 1 with the sun on or above the
	// horizon, exp(−0.25 · depression°) below it (DaylightModel.twilight_palette
	// — the same curve main.gd runs the ambient on). Civil twilight (−6°) is
	// still 22 % lit, nautical (−12°) 5 %, gone by −21°. The old form was black
	// by −7° while the ground ambient was still two-thirds of daylight — which
	// is half of why dusk read as a switch. It is what the horizon, cirrus and
	// cloud blocks read as "how dark is it".
	float _night_amount = 1.0 - min( _daylight / 0.55, 1.0 );
	// Totality / deep partial eclipse: daylight collapses while the sun is still up.
	if( LIGHT0_DIRECTION.y > 0.0 && eclipse_obscuration > 0.05 )
	{
		float _eclipse_night = eclipse_obscuration * ( eclipse_obscuration > 0.92 ? 0.95 : 0.55 );
		_night_amount = max( _night_amount, _eclipse_night );
	}
	// The dark sky = a near-black zenith→horizon gradient plus three separate,
	// user-controlled light sources, so a Bortle-1 wilderness night is all three
	// at zero and a suburban night is light pollution up.
	vec3 _night = mix( night_bottom_color, night_top_color, _eyedir_y );
	float _up = clamp( EYEDIR.y, 0.0, 1.0 );
	// Airglow: strongest along grazing sight lines through the emitting layer,
	// fading toward the zenith; cut off at the horizon.
	float _ag = exp( -_up * 5.0 ) * smoothstep( -0.04, 0.03, EYEDIR.y );
	_night += airglow_color * airglow_strength * 0.12 * _ag;
	// Light pollution: cubic falloff from the horizon plus a dim floor everywhere.
	float _lp = pow( 1.0 - _up, 3.0 );
	_night += light_pollution_color * light_pollution * ( 0.02 + 0.16 * _lp );
	// Moonlight: scattered moon-blue, a little brighter low in the sky, gone at new moon.
	float _moon_up = LIGHT1_ENABLED ? clamp( LIGHT1_DIRECTION.y * 3.0, 0.0, 1.0 ) : 0.0;
	float _moon_sky = _moon_up * _moon_phase_lit * moon_sky_glow;
	_night += vec3( 0.06, 0.09, 0.16 ) * _moon_sky * ( 0.55 + 0.45 * ( 1.0 - _up ) );
	_sky_color = mix( _sky_color, _night, _night_amount );
	// Sky luminance the STARS block uses to wash out the faint stars: the whole
	// sky, so the twilight glow hides them exactly as the moon does and they
	// emerge as it fades instead of on a separate timer.
	float _night_sky_lum = dot( _sky_color, vec3( 0.299, 0.587, 0.114 ) );

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

	//////////////////// HAZARD HAZE ///////////////////////////////////////////////////////////////
	// Wildfire smoke / blowing dust take over the sky itself. See the uniform
	// block for why this sits here rather than at the end of sky().
	if( hazard_haze > 0.003 )
	{
		// Grazing lines of sight pass through far more aerosol than the zenith.
		float _lo = 1.0 - smoothstep( -0.05, 0.60, EYEDIR.y );
		float _h = hazard_haze * mix( 1.0 - hazard_horizon_bias, 1.0, _lo );
		COLOR = mix( COLOR, hazard_haze_color, clamp( _h, 0.0, 1.0 ) );
	}

	//////////////////// MOON //////////////////////////////////////////////////////////////////////
	float _moon_amount = 0.0;
	if( LIGHT1_ENABLED )
	{
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
		// The spatial moon mask takes a bite out of the sun disc.
		// (Hack removed: new moon can now safely occlude the sun disc without leaving a black hole in the sky)
		float _moon_occlude = _moon_amount;
		
		// The physical sun disc is blocked by the moon's shape, or by the horizon.
		float _sun_disc_visible = ( 1.0 - _horizon_amount ) * ( 1.0 - max( _moon_occlude, eclipse_obscuration ) );
		
		// Atmospheric scattering (aureole and glow) happens IN FRONT OF the moon.
		// It should only be dimmed by the global loss of sunlight during an eclipse,
		// and never spatially masked by the moon's geometry.
		float _atmos_illumination = ( 1.0 - _horizon_amount ) * ( 1.0 - eclipse_obscuration );

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
			_aur *= sun_aureole * ( 0.30 + _sun_redden * 1.5 * twilight_drama ) * _atmos_illumination;
			COLOR += _aur_col * _aur;
		}

		// Soft radial corona hugging the disc — the "glow" instead of a hard bright disc.
		if( sun_glow > 0.0 && LIGHT0_DIRECTION.y > -0.12 )
		{
			float _glow_radius = _sun_size * sun_glow_size * mix( 1.0, twilight_drama, _sun_redden );
			float _sg = pow( max( 0.0, 1.0 - _sun_view_dist / _glow_radius ), 2.5 );
			vec3 _glow_col = mix( sun_glow_color, _sun_warm, _sun_redden );
			COLOR = mix( COLOR, _glow_col, clamp( _sg * sun_glow * _atmos_illumination, 0.0, 1.0 ) );
		}

		// Finding sun disc and edge blur
		float _sun_amount = clamp(( 1.0 - _sun_distance / _sun_size ) / sun_blur, 0.0, 1.0 );
		if( _sun_amount > 0.0 )
		{
			_sun_amount = clamp( _sun_amount * _sun_disc_visible, 0.0, 1.0 );
			vec3 _sun_col = _sun_disc_color;
			// Leveling the "glow" in color
			if( _sun_col.r > 1.0 || _sun_col.g > 1.0 || _sun_col.b > 1.0 )
				_sun_col *= _sun_amount;
			COLOR = mix( COLOR, _sun_col, _sun_amount );
		}
	}

	//////////////////// STARS /////////////////////////////////////////////////////////////
	// Gate where the twilight ramp below reaches exactly zero (LIGHT0.y = +0.05). Gating
	// at 0.0 switched ~7% of the star brightness on in one frame at sunset.
	if( EYEDIR.y > -0.05 && LIGHT0_DIRECTION.y < 0.05 )
	{
		vec3 _view_dir = normalize( EYEDIR );

		// World direction -> equatorial (RA, Dec) through the basis StarSystem pushes:
		//   dec = asin( v·P );  hour angle H = atan2( −v·E, v·M ), positive WEST;  RA = LST − H.
		// Mirrored line for line in StarSkyMath.shader_uv_for_direction — keep them in
		// sync; core/astronomy/star_sky_selftest.gd is what proves they still agree.
		float _sin_dec = clamp( dot( _view_dir, stars_axis_pole ), -1.0, 1.0 );
		float _dec = asin( _sin_dec );
		float _ha = atan( -dot( _view_dir, stars_axis_east ), dot( _view_dir, stars_axis_meridian ) );
		float _ra = radians( stars_lst ) - _ha;

		// Equatorial -> texture UV through the registration (see the uniform block).
		float _u = fract( ( _ra - radians( stars_ra_at_u0_deg ) ) * stars_ra_direction / TAU );
		float _vv = 0.5 - _dec / PI;
		if( stars_north_up < 0.5 ) { _vv = 1.0 - _vv; }
		vec2 _stars_uv = vec2( _u, _vv );

		// --- Sample: the sharp centre plus a 4-tap cross ONE TEXEL out ----------------
		vec2 _px = stars_texel;
		vec3 _stars_sharp = texture( stars_texture, _stars_uv ).rgb;
		vec3 _t0 = texture( stars_texture, _stars_uv + vec2( _px.x, 0.0 ) ).rgb;
		vec3 _t1 = texture( stars_texture, _stars_uv - vec2( _px.x, 0.0 ) ).rgb;
		vec3 _t2 = texture( stars_texture, _stars_uv + vec2( 0.0, _px.y ) ).rgb;
		vec3 _t3 = texture( stars_texture, _stars_uv - vec2( 0.0, _px.y ) ).rgb;
		vec3 _soft = ( _t0 + _t1 + _t2 + _t3 ) * 0.25;
		// The DIFFUSE (Milky Way) source: a real box blur from the map's mip chain —
		// LOD 3 on the 8k map, 4 on the 16k (≈ 8 texels = 0.35° of sky either way;
		// Stellarium's own Milky Way texture is grainy and LOD 2 still showed it).
		// A sparse ring of far taps was tried first and drew a SQUARE of dots
		// around every faint star. min() with the 1-texel cross keeps a bright
		// disc's blur from bleeding a halo past its own edge.
		float _mw_lod = 3.0 + log2( max( 1.0 / ( stars_texel.x * 8192.0 ), 1.0 ) );
		vec3 _wide = min( textureLod( stars_texture_soft, _stars_uv, _mw_lod ).rgb, _soft );
		// Point size: erode (min over the cross) shrinks every disc by a texel,
		// dilate (max) grows it; continuous through mix.
		vec3 _nmin = min( min( _t0, _t1 ), min( _t2, _t3 ) );
		vec3 _nmax = max( max( _t0, _t1 ), max( _t2, _t3 ) );
		vec3 _stars_color = mix( _stars_sharp, min( _stars_sharp, _nmin ), clamp( -stars_point_size, 0.0, 1.0 ) );
		_stars_color = mix( _stars_color, max( _stars_color, _nmax ), clamp( stars_point_size, 0.0, 1.0 ) );
		// Optional soft halo (off by default).
		if( stars_glow > 0.001 )
		{
			_stars_color = mix( _stars_color, max( _stars_color, _soft * 1.5 ), clamp( stars_glow, 0.0, 1.0 ) );
		}
		// Long-exposure trails: a star's EARLIER positions lie at larger RA on the same
		// declination (it rose in the east), so a trail is a straight walk along u.
		if( star_trails > 0.001 )
		{
			float _trail_span = radians( 8.0 + star_trail_length * 40.0 );
			vec3 _trail_accum = _stars_color;
			const int TRAIL_SAMPLES = 5;
			for( int _ti = 1; _ti <= TRAIL_SAMPLES; _ti++ )
			{
				float _td = _trail_span * ( float( _ti ) / float( TRAIL_SAMPLES ) );
				vec2 _tuv = vec2( fract( _u + stars_ra_direction * _td / TAU ), _vv );
				_trail_accum += texture( stars_texture, _tuv ).rgb;
			}
			_trail_accum /= float( TRAIL_SAMPLES + 1 );
			_stars_color = mix( _stars_color, _trail_accum, clamp( star_trails, 0.0, 1.0 ) );
		}

		// --- Split the map into star CORES and the diffuse MILKY WAY ------------------
		// The export draws stars as saturated discs (luminance ≥ ~0.5) over a dim
		// diffuse background (≤ ~0.3), so luminance separates the two cleanly.
		const vec3 _LUMA = vec3( 0.299, 0.587, 0.114 );
		float _lum = dot( _stars_color, _LUMA );
		float _core = smoothstep( 0.30, 0.60, _lum );
		// Star colour: the core clipped to white in the export, so read the tint
		// off the fringe (the 4-tap average) and re-apply it to the core's luminance.
		float _soft_lum = max( dot( _soft, _LUMA ), 1e-4 );
		vec3 _fringe_chroma = clamp( _soft / _soft_lum, 0.0, 4.0 ) - vec3( 1.0 );
		vec3 _star_part = vec3( _lum ) * max( vec3( 1.0 ) + _fringe_chroma * stars_saturation, vec3( 0.0 ) );
		_star_part = pow( max( _star_part, vec3( 0.0 ) ), vec3( stars_contrast ) );
		// Milky Way: the smoothed wide sample (never the noisy single texel), its
		// own gain, tint and saturation, and no contrast crush. Stars fainter than
		// the core threshold live in the same path — the ring keeps them soft.
		vec3 _mw_part = _wide * milkyway_gain * milkyway_tint;
		float _mw_lum = dot( _mw_part, _LUMA );
		_mw_part = max( mix( vec3( _mw_lum ), _mw_part, milkyway_saturation ), vec3( 0.0 ) );
		_stars_color = mix( _mw_part, _star_part, _core );

		// Background cut — raised by the sky's own glow (moon, light pollution):
		// under a bright sky the faint stars and the Milky Way are the first to go.
		float _cut = stars_background_cut + stars_wash * _night_sky_lum * 6.0;
		float _bg_mask = smoothstep( _cut, _cut * 3.0 + 0.02, dot( _stars_color, _LUMA ) );
		_stars_color *= _bg_mask;

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

			// Apply twinkle only to the star cores — the Milky Way does not scintillate.
			float _star_brightness = dot( _stars_color, _LUMA );
			float _twinkle_strength = stars_twinkle * ( 1.0 - _star_brightness * 0.5 ) * _horizon_twinkle_boost * _core;

			_stars_color *= 1.0 + ( _twinkle_amount - 0.5 ) * _twinkle_strength;
		}

		// Fade stars based on how dark the sky is (twilight transition): the
		// brightest stars show at −2°, the full field by −17°.
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

	//////////////////// CIRRUS //////////////////////////////////////////////////////////////////
	// High, wispy, streaked clouds rendered independently of the cumulus layer (so they can
	// appear in otherwise-clear skies).  A single stretched-and-rotated fractal makes the thin
	// filament look; they catch sunset color dramatically since they sit high in the atmosphere.
	if( EYEDIR.y > 0.02 && cirrus_amount > 0.01 && LIGHT0_DIRECTION.y > -0.25 )
	{
		vec2 _cir_base = EYEDIR.xz / sqrt( EYEDIR.y );
		// Sample the streak noise directly (smoothly driven by accumulated offset)
		float _cir_noise = sample_cirrus_noise( _cir_base );
		// Coverage widens the accepted band; higher coverage = more of the sky filled.
		float _cir_lo = mix( 0.62, 0.40, cirrus_coverage );
		float _cir = smoothstep( _cir_lo, _cir_lo + 0.28, _cir_noise ) * cirrus_amount;
		// Fade out toward the horizon and at night.
		_cir *= clamp( ( EYEDIR.y - 0.02 ) / 0.14, 0.0, 1.0 );
		_cir *= 1.0 - _night_amount * 0.92;
		// The EYEDIR.xz/sqrt(EYEDIR.y) projection collapses to a point at the zenith,
		// producing a colored "pinch" swirl straight overhead — fade the top cap to hide it.
		_cir *= 1.0 - smoothstep( 0.88, 0.995, EYEDIR.y );

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
		
		// Accumulated CPU-driven offset to prevent boiling/jumping.
		// Slight variation in drift vector per layer to simulate volumetric shearing.
		vec2 _clouds_movement_top = cloud_uv_offset * 1.1;
		float _noise_top = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement_top ) * clouds_scale, 0, 0.5 );
		
		vec2 _clouds_movement_mid = vec2(cloud_uv_offset.x * 0.97, cloud_uv_offset.y * 1.07);
		float _noise_middle = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement_mid ) * clouds_scale, 1, 0.75 );
		
		// Domain warp the bottom layer using the top layers to dynamically evolve the cloud shapes
		vec2 _clouds_movement_bot = vec2(cloud_uv_offset.x * 1.01, cloud_uv_offset.y * 0.89);
		vec2 _warp = vec2(_noise_top - 0.5, _noise_middle - 0.5) * 0.08;
		
		float _noise_bottom = gen_fractal_ping_pong( ( _sky_uv + _clouds_movement_bot + _warp ) * clouds_scale, 2, 1.0 );
		// Smoothstep with the addition of a noise value from a lower level gives a nice, deep result
		_noise_bottom = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_bottom );
		_noise_middle = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_middle + _noise_bottom * 0.2 ) * 1.1;
		_noise_top = smoothstep( clouds_cutoff, clouds_cutoff + clouds_fuzziness, _noise_top + _noise_middle * 0.4 ) * 1.2;
		float _clouds_amount = clamp( _noise_top + _noise_middle + _noise_bottom, 0.0, 1.0 );
		// Fading clouds near the horizon
		_clouds_amount *= clamp( abs( EYEDIR.y ) / clouds_blur, 0.0, 1.0 );
		// Hide the zenith projection singularity (same pinch as the cirrus layer).
		_clouds_amount *= 1.0 - smoothstep( 0.88, 0.995, EYEDIR.y );

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

	//////////////////// RAINBOW /////////////////////////////////////////////////////////////////
	// Rendered AFTER the clouds so the bow sits IN FRONT of them (real rainbows are between the
	// observer and the rain curtain, so they read over/through the cloud deck rather than behind).
	// Primary + secondary bows opposite the sun (Descartes minimum-deviation ~42° / ~51°).
	// LIGHT0_DIRECTION points TOWARD the sun (day => .y > 0; stars gate on .y < 0 near line ~536),
	// so the antisolar point is -LIGHT0_DIRECTION. A real bow only exists when the sun is below
	// ~42° altitude (otherwise the whole arc is under the horizon) — this gate also removes the
	// zenith "color pinch" that appears when the 42° band crosses straight up.
	if( rainbow_strength > 0.01 && LIGHT0_DIRECTION.y > 0.02 && LIGHT0_DIRECTION.y < 0.70 && EYEDIR.y > 0.02 )
	{
		vec3 _to_sun = normalize( LIGHT0_DIRECTION );   // up toward the sun during the day
		vec3 _antisun = -_to_sun;                       // antisolar point (near/below horizon)
		vec3 _eye_n = normalize( EYEDIR );
		float _theta = acos( clamp( dot( _eye_n, _antisun ), -1.0, 1.0 ) );
		const float _PRIMARY = 0.733038;   // 42°
		const float _SECONDARY = 0.890118; // 51°
		const float _BAND_SIG = 0.017;     // ~1° core half-width
		const float _BAND_GLOW = 0.05;     // soft translucent halo

		// Restrict to the principal vertical plane through the sun so the full 360° cone does
		// not render as a color ring/wheel — keep the upright arc that rises from the horizon.
		vec3 _plane_n = cross( _to_sun, vec3( 0.0, 1.0, 0.0 ) );
		float _arc_focus = 1.0;
		if( length( _plane_n ) > 0.05 )
		{
			_plane_n = normalize( _plane_n );
			float _off_plane = abs( dot( _eye_n, _plane_n ) );
			_arc_focus = 1.0 - smoothstep( 0.45, 0.72, _off_plane );
		}

		float _hz_fade = smoothstep( 0.02, 0.22, EYEDIR.y );
		float _gate = _arc_focus * _hz_fade * rainbow_strength;

		// Primary bow — Gaussian core + wide glow for a bright translucent arc.
		float _dev_p = abs( _theta - _PRIMARY );
		float _core_p = exp( -_dev_p * _dev_p / ( _BAND_SIG * _BAND_SIG ) );
		float _glow_p = exp( -_dev_p * _dev_p / ( _BAND_GLOW * _BAND_GLOW ) ) * 0.4;
		float _spec_p = clamp( ( _theta - 0.695 ) / 0.052, 0.0, 1.0 );
		vec3 _col_p = _rainbow_spectrum( _spec_p );
		COLOR += _col_p * ( _core_p + _glow_p ) * _gate * 0.85;

		// Secondary bow — reversed spectrum, fainter, outside the primary.
		float _dev_s = abs( _theta - _SECONDARY );
		float _core_s = exp( -_dev_s * _dev_s / ( _BAND_SIG * _BAND_SIG * 1.1 ) );
		float _glow_s = exp( -_dev_s * _dev_s / ( _BAND_GLOW * _BAND_GLOW ) ) * 0.25;
		float _spec_s = clamp( ( _theta - 0.855 ) / 0.048, 0.0, 1.0 );
		vec3 _col_s = _rainbow_spectrum( 1.0 - _spec_s );
		COLOR += _col_s * ( _core_s + _glow_s ) * _gate * 0.16;
	}

}

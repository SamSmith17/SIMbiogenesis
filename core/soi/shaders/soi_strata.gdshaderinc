// The SoI cutaway's below-ground look — a Pacific-Northwest forest soil
// profile — shared by the soil bowl (soi_subsurface.gdshader: the snowglobe's
// underside, Site Plan's rim) and the Elevation / Hydro Lab cut face
// (soi_section_cap.gdshader), so all of them read as ONE block of earth.
//
// Top to bottom (horizon thicknesses scale with the SoI radius, `k`, so a
// 1 m humus layer is still legible on a 300 m globe):
//   O  litter + humus, near-black brown, needle flecks
//   A  dark brown topsoil, rooted
//   B  iron-rich red-brown subsoil, mottled (the PNW andisol / ultisol colour)
//   BC/C weathered glacial till, cobbles, fading darker with depth
//   bedrock: columnar basalt, fractured
//   groundwater: a FLAT saturated zone near the bottom of the globe — a water
//   table does not follow the slope above it (the old 15 m-below-surface band
//   did, and flooded most of a hillside cut)
// with a couple of meandering, branching percolation channels carrying water
// down from just under the surface to that water table, flowing.
//
// The near-field terrain texture (ground049a, TerrainBuilder.near_detail_*)
// supplies the grain: its high-passed luminance and its normal map, so the
// soil has the same crumbly relief as the ground the player walks on. Horizon
// colours are authored in sRGB and stored here LINEAR (the cut is drawn as
// self-lit poster colour); the UI legend mirrors the sRGB values
// (GraphSoilLegend.COLORS — edit both).

float soi_hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 soi_hash22(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

float soi_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(soi_hash2(i), soi_hash2(i + vec2(1.0, 0.0)), u.x),
			mix(soi_hash2(i + vec2(0.0, 1.0)), soi_hash2(i + vec2(1.0, 1.0)), u.x), u.y);
}

// ~0..0.94, mean ~0.47.
float soi_fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * soi_vnoise(p);
		p = p * 2.03 + vec2(17.1, 5.3);
		a *= 0.5;
	}
	return s;
}

// x = distance to the nearest feature point, y = F2 − F1 (0 on a cell edge),
// z = the nearest cell's hash.
vec3 soi_voronoi(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	float id = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = soi_hash22(i + g);
			float d = length(g + o - f);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = soi_hash2(i + g + vec2(3.1, 7.7));
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	return vec3(f1, f2 - f1, id);
}

// Horizon thickness scale from the SoI radius.
float soi_horizon_k(float r) {
	return clamp(r / 45.0, 1.0, 5.0);
}

// The water table: a level surface near the bottom of the globe.
float soi_water_level(vec4 c_r) {
	return c_r.y - c_r.w * 0.70;
}

// Horizon colours (linear; sRGB in the comments = GraphSoilLegend.COLORS).
const vec3 SOI_C_LITTER = vec3(0.040, 0.016, 0.0075);  // #382619
const vec3 SOI_C_TOPSOIL = vec3(0.088, 0.036, 0.013);  // #543824
const vec3 SOI_C_SUBSOIL = vec3(0.300, 0.100, 0.045);  // #965a3c
const vec3 SOI_C_TILL = vec3(0.270, 0.130, 0.060);     // #8c6647
const vec3 SOI_C_PARENT = vec3(0.150, 0.093, 0.056);   // #6b5745
const vec3 SOI_C_DEEP = vec3(0.018, 0.013, 0.011);     // #292421
const vec3 SOI_C_BASALT = vec3(0.043, 0.039, 0.039);   // #3d3b3b
const vec3 SOI_C_STONE = vec3(0.300, 0.280, 0.240);    // #948f85
const vec3 SOI_C_WATER_DEEP = vec3(0.006, 0.060, 0.170); // #1a4773
const vec3 SOI_C_WATER = vec3(0.170, 0.580, 1.000);    // #73c7ff
const vec3 SOI_C_WATER_HI = vec3(0.700, 0.930, 1.000); // #d9f7ff

// Texture grain + relief from the terrain's near-field ground maps.
// Returns vec2(luminance multiplier, relief shade).
vec2 soi_soil_grain(vec2 p, sampler2D tex, sampler2D nrm, float use_tex, float scale) {
	if (use_tex < 0.5) {
		float g = soi_fbm(p * 1.7 / scale) - 0.47;
		return vec2(1.0 + g * 0.55, 1.0);
	}
	vec2 uv1 = p / (6.0 * scale);
	vec2 uv2 = p / (1.6 * scale) + vec2(0.37, 0.61);
	vec3 a1 = texture(tex, uv1).rgb;
	vec3 a2 = texture(tex, uv2).rgb;
	vec3 lumw = vec3(0.299, 0.587, 0.114);
	// High-pass: the texture's own local contrast, not its tan base colour.
	float hp1 = dot(a1, lumw) - dot(textureLod(tex, uv1, 6.0).rgb, lumw);
	float hp2 = dot(a2, lumw) - dot(textureLod(tex, uv2, 6.0).rgb, lumw);
	// The ground049a maps are low-contrast by design (they sit over a photo),
	// so the high-pass is boosted hard; the relief comes from the normal map
	// lit from the upper left, like a face of dug earth.
	vec2 n = texture(nrm, uv1).xy * 2.0 - 1.0;
	vec2 n2 = texture(nrm, uv2).xy * 2.0 - 1.0;
	float shade = 1.0 + 0.45 * dot(n * 0.65 + n2 * 0.35, normalize(vec2(-0.55, 0.83)));
	return vec2(1.0 + hp1 * 5.0 + hp2 * 3.5, shade);
}

// The soil profile at face point p = (horizontal metres, world y), below a
// ground surface at `surf`, in the SoI sphere c_r = (centre, radius).
vec3 soi_soil_profile(vec2 p, float surf, vec4 c_r) {
	float k = soi_horizon_k(c_r.w);
	float d = max(surf - p.y, 0.0);
	float bottom = c_r.y - c_r.w;
	float tn = clamp(d / max(surf - bottom, 1.0), 0.0, 1.0);
	// Horizon boundaries undulate along the face (never ruler-straight).
	float n1 = soi_fbm(vec2(p.x * 0.045, 1.3)) - 0.47;
	float n2 = soi_fbm(vec2(p.x * 0.028, 7.9)) - 0.47;
	// (GraphSoilLegend.BOUNDS_K mirrors these four bases.)
	float b_o = 0.6 * k * (1.0 + 0.9 * n1);
	float b_a = 2.6 * k * (1.0 + 0.6 * n2);
	float b_b = 8.0 * k * (1.0 + 0.45 * n1);
	float b_bc = 17.0 * k * (1.0 + 0.35 * n2);
	float soft = 0.30 * k;
	vec3 col = SOI_C_LITTER;
	// Needle / litter flecks in the O horizon — soft blobs, not pixel squares.
	float fleck = smoothstep(0.70, 0.86, soi_vnoise(p * vec2(5.0, 9.0) / k));
	col = mix(col, vec3(0.13, 0.055, 0.02), fleck * 0.55);
	col = mix(col, SOI_C_TOPSOIL, smoothstep(b_o - soft * 0.5, b_o + soft * 0.5, d));
	col = mix(col, SOI_C_SUBSOIL, smoothstep(b_a - soft, b_a + soft * 1.5, d));
	// Iron mottling through B — redder and paler patches.
	float mott = soi_fbm(p * vec2(0.22, 0.42) / k);
	float in_b = smoothstep(b_a, b_a + soft, d) * (1.0 - smoothstep(b_b, b_b + 2.0 * soft, d));
	col *= mix(1.0, 0.78 + 0.48 * mott, in_b);
	col = mix(col, SOI_C_TILL, smoothstep(b_b - 2.0 * soft, b_b + 3.0 * soft, d));
	col = mix(col, SOI_C_PARENT, smoothstep(b_bc - 4.0 * soft, b_bc + 4.0 * soft, d));
	// Fades darker all the way to the bottom of the globe.
	col = mix(col, SOI_C_DEEP, smoothstep(0.22, 1.0, tn) * 0.8);
	// Bedrock: columnar basalt (cells stretched vertically) with dark joints.
	float rock_top = 0.46 + 0.12 * (soi_fbm(vec2(p.x * 0.012, 3.3)) - 0.47);
	float rock = smoothstep(rock_top - 0.05, rock_top + 0.03, tn);
	if (rock > 0.001) {
		vec3 v = soi_voronoi(p * vec2(0.22, 0.06) / sqrt(k));
		vec3 basalt = SOI_C_BASALT * (0.75 + 0.5 * v.z);
		basalt *= mix(0.25, 1.0, smoothstep(0.0, 0.10, v.y));
		col = mix(col, basalt, rock);
	}
	// Glacial-till cobbles: rounded stones, denser with depth, none in O/A.
	float stone_zone = smoothstep(b_a, b_b, d) * (1.0 - rock);
	if (stone_zone > 0.001) {
		// Fewer, bigger, duller cobbles — a sprinkle of bright dots read as
		// snow from orbit.
		vec3 v = soi_voronoi(p * 0.26 / sqrt(k));
		float r = 0.18 + 0.20 * v.z;
		float has = step(v.z, 0.10 + 0.25 * smoothstep(b_b, b_bc * 1.4, d));
		float st = (1.0 - smoothstep(r - 0.06, r, v.x)) * has * stone_zone;
		vec3 stone = SOI_C_STONE * (0.40 + 0.35 * soi_hash2(vec2(v.z, 1.0)));
		stone *= mix(0.5, 1.0, smoothstep(r, r * 0.3, v.x));
		col = mix(col, stone, st * 0.9);
	}
	// Roots: thin wiggly near-vertical runs through O, A and into B.
	float rw = 1.6 * k;
	float rc = floor(p.x / rw);
	float rh = soi_hash2(vec2(rc, 4.2));
	float root_len = (1.5 + 4.5 * rh) * k;
	float rx = (rc + 0.5 + 0.35 * sin(d * 0.9 / sqrt(k) + rh * 30.0)) * rw;
	float taper = 1.0 - smoothstep(0.0, root_len, d);
	float root = (1.0 - smoothstep(0.03 * k * taper, 0.06 * k * taper + 0.02, abs(p.x - rx)))
			* taper * step(rh, 0.7);
	col = mix(col, vec3(0.02, 0.012, 0.007), root * 0.6);
	return col;
}

// Percolation channels: a couple of meandering streams of water per ~70 m,
// each forking twice, from just under the surface down to the water table.
// Returns vec4(core, wet halo, flow highlight, seep glow at the water table).
vec4 soi_channels(vec2 p, float surf, float water_top, float k, float t) {
	float d = surf - p.y;
	float span = surf - water_top;
	if (span < 2.0 || d < 0.0 || p.y < water_top - 4.0 * k) {
		return vec4(0.0);
	}
	// One channel per ~120 m on average, each forking twice: a couple of
	// branching streams across a globe, not a hatching.
	float W = 120.0;
	float ci = floor(p.x / W);
	float core = 0.0;
	float halo = 0.0;
	float hi = 0.0;
	float seep = 0.0;
	float w0 = (0.8 + 0.18 * k) * (1.0 + 0.5 * smoothstep(0.0, span, d));
	// Soaks in under the humus, so no channel in the top few decimetres.
	float start = smoothstep(0.35 * k, 1.2 * k, d);
	for (int o = -1; o <= 1; o++) {
		float cell = ci + float(o);
		float h = soi_hash2(vec2(cell, 3.7));
		if (h > 0.65) {
			continue;
		}
		float s0 = (cell + 0.2 + 0.6 * soi_hash2(vec2(cell, 9.1))) * W;
		float sc = s0 + 4.0 * k * sin(d * 0.045 + h * 20.0) + 1.6 * k * sin(d * 0.13 + h * 7.0);
		for (int b = 0; b < 3; b++) {
			float sx = sc;
			float w = w0;
			float on = 1.0;
			if (b > 0) {
				float hb = soi_hash2(vec2(cell, 21.0 + float(b)));
				float db = (0.18 + 0.38 * hb) * span;
				on = smoothstep(db, db + 1.0, d);
				float dir = b == 1 ? 1.0 : -1.0;
				float drift = min(max(d - db, 0.0) * (0.40 + 0.35 * hb), W * 0.42);
				sx = sc + dir * drift + 2.2 * k * sin(d * 0.07 + hb * 11.0) * smoothstep(db, db + 12.0, d);
				w = w0 * 0.72;
			}
			if (on <= 0.0) {
				continue;
			}
			float dist = abs(p.x - sx);
			core = max(core, on * (1.0 - smoothstep(w * 0.42, w * 0.5 + 0.12, dist)));
			halo = max(halo, on * (1.0 - smoothstep(w * 0.5, w * 3.2, dist)));
			// Pulses travel DOWN the channel (phase grows with depth over time).
			float ph = d * 0.16 / sqrt(k) - t * 2.4 + h * 6.283 + float(b) * 1.7;
			hi = max(hi, on * (1.0 - smoothstep(w * 0.2, w * 0.45, dist))
					* smoothstep(0.55, 1.0, sin(ph)));
			// Where it reaches the water table: a small bright seep.
			float dy = p.y - water_top;
			seep = max(seep, on * exp(-dist / (2.5 * w)) * exp(-abs(dy) / (1.6 * k)));
		}
	}
	core *= start;
	halo *= start;
	hi *= start;
	return vec4(core, halo, hi, seep);
}

// The whole face: profile + texture grain + groundwater + channels.
// `channels_on` 0 keeps it calm (Site Plan's rim).
vec3 soi_soil(vec2 p, float surf, vec4 c_r, float t, sampler2D tex, sampler2D nrm,
		float use_tex, float channels_on) {
	float k = soi_horizon_k(c_r.w);
	vec3 col = soi_soil_profile(p, surf, c_r);
	vec2 gr = soi_soil_grain(p, tex, nrm, use_tex, sqrt(k));
	col *= clamp(gr.x, 0.45, 1.7) * gr.y;
	// Groundwater: level top with a gentle wobble, a damp capillary fringe
	// above it, and slow lateral flow lines inside it.
	float wl = soi_water_level(c_r) + 1.5 * k * (soi_fbm(vec2(p.x * 0.02, 5.1)) - 0.47);
	float below = 1.0 - smoothstep(wl - 0.4, wl + 0.4, p.y);
	float fringe = (1.0 - smoothstep(wl, wl + 4.0 * k, p.y)) * (1.0 - below);
	col = mix(col, col * vec3(0.55, 0.62, 0.78), fringe * 0.8);
	if (below > 0.001) {
		float depth_w = clamp((wl - p.y) / max(c_r.w * 0.3, 1.0), 0.0, 1.0);
		vec3 sat = mix(col * 0.35 + SOI_C_WATER_DEEP * 0.9, SOI_C_WATER_DEEP * 0.55, depth_w);
		float flow = soi_fbm(vec2(p.x * 0.05 - t * 0.12, p.y * 0.6));
		float line = smoothstep(0.62, 0.75, flow) * (1.0 - depth_w * 0.6);
		sat += SOI_C_WATER * 0.10 * line;
		// A bright meniscus right at the table.
		sat += SOI_C_WATER * 0.35 * (1.0 - smoothstep(0.0, 0.8 * k, wl - p.y));
		col = mix(col, sat, below);
	}
	if (channels_on > 0.5) {
		vec4 ch = soi_channels(p, surf, wl, k, t);
		col *= 1.0 - 0.45 * ch.y;                    // wet soil around a channel
		col = mix(col, col * vec3(0.6, 0.75, 1.0), ch.y * 0.35);
		vec3 water = mix(SOI_C_WATER * 0.55, SOI_C_WATER_HI, ch.z);
		col = mix(col, water, ch.x);
		col += SOI_C_WATER * 0.45 * ch.w;
	}
	return col;
}

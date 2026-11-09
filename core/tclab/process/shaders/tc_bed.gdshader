// The charge in a vessel (TC Process Lab): a cylinder whose colour comes
// from the bed's own cells. `cells` is NR wide and NZ high per element domain
// (domains stacked), rgb = what the cell is (wet wood, dry, pyrolysing, char),
// a = how hot it glows (0 below ~420 °C, 1 at ~800 °C). Where the section
// plane cuts the charge the back faces seen through the cut are coloured by
// the point where the view ray crosses the plane, so the cut face is a real
// cross-section of the bed: the dry ring, the dark pyrolysis front, the
// glowing char round each element.
//
// The mesh is one unit high; `bed_h` is the charge's height NOW (it settles
// as it dries and chars), so the same cells are drawn over a shorter pile.
// Top vertices (UV2.x = 1) are heaped by a noise so the surface reads as a
// pile of pieces, shaded flat per facet. The glow follows temperature alone:
// dull red, orange, then yellow, and back down to black char as it cools.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D cells : source_color, filter_linear, repeat_disable;
uniform int n_dom = 1;
uniform int nr = 8;
uniform vec4 dom[4];            // xz centre (m, vessel frame), r_in, r_out
uniform vec4 el_glow[4];        // each element: rgb, strength
uniform float bed_h = 0.3;
uniform float piece_m = 0.011;  // chip / pellet size
uniform float heap_m = 0.010;   // how uneven the top is
uniform float flicker = 0.0;    // the lab clock (embers shimmer; stops when paused)
uniform mat4 to_vessel;         // world → vessel frame (m)
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);

varying vec3 v_world;
varying float v_top;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float vnoise2(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash3(vec3(i, 1.0));
	float b = hash3(vec3(i + vec2(1.0, 0.0), 1.0));
	float c = hash3(vec3(i + vec2(0.0, 1.0), 1.0));
	float d = hash3(vec3(i + vec2(1.0, 1.0), 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_top = UV2.x;
	vec3 v = VERTEX;
	float heap = 0.0;
	if (UV2.x > 0.5) {
		// Heaped in the middle of each piece-sized patch, level at the wall.
		heap = (vnoise2(v.xz / (piece_m * 2.2)) - 0.35) * heap_m * UV2.y
			+ (vnoise2(v.xz / (piece_m * 7.0) + vec2(4.7, 1.3)) - 0.5) * heap_m * 1.6 * UV2.y;
	}
	// Lifted a hair off the vessel's floor (the two faces would flicker).
	v.y = max(v.y * bed_h + heap, 0.003);
	VERTEX = v;
	v_world = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
}

vec4 cell_at(vec3 pv, out float el, out vec3 el_rgb) {
	el = 0.0;
	el_rgb = vec3(0.0);
	int best = 0;
	float bd = 1.0e9;
	for (int i = 0; i < 4; i++) {
		if (i >= n_dom) {
			break;
		}
		float d = length(pv.xz - dom[i].xy) / max(dom[i].w, 1.0e-3);
		if (d < bd) {
			bd = d;
			best = i;
		}
	}
	vec4 D = dom[best];
	float r = length(pv.xz - D.xy);
	if (r < D.z) {
		el = 1.0;
		el_rgb = el_glow[best].rgb * el_glow[best].a * 3.0;
		return vec4(mix(vec3(0.35, 0.33, 0.32), el_glow[best].rgb, el_glow[best].a), 0.0);
	}
	float u = clamp((r - D.z) / max(D.w - D.z, 1.0e-4), 0.0, 1.0);
	float v = clamp(pv.y / max(bed_h, 1.0e-4), 0.0, 1.0);
	float fn = float(nr);
	vec2 uv = vec2((u * (fn - 1.0) + 0.5) / fn, (float(best) + v) / float(n_dom));
	return texture(cells, uv);
}

// Hot solids glow by temperature: dull red first, orange, then yellow.
vec3 incandescence(float g) {
	vec3 c = mix(vec3(0.42, 0.02, 0.0), vec3(1.0, 0.30, 0.04), smoothstep(0.0, 0.55, g));
	c = mix(c, vec3(1.0, 0.72, 0.28), smoothstep(0.6, 1.0, g));
	return c * (0.25 + 2.6 * g * g) * smoothstep(0.0, 0.06, g);
}

void fragment() {
	if (dot(v_world, cut_plane.xyz) > cut_plane.w) {
		discard;
	}
	vec3 p = v_world;
	if (!FRONT_FACING) {
		vec3 ro = CAMERA_POSITION_WORLD;
		vec3 rd = normalize(v_world - ro);
		float den = dot(rd, cut_plane.xyz);
		if (abs(den) > 1.0e-4) {
			float t = (cut_plane.w - dot(ro, cut_plane.xyz)) / den;
			if (t > 0.0) {
				p = ro + rd * t;
			}
		}
		NORMAL = normalize((VIEW_MATRIX * vec4(cut_plane.xyz, 0.0)).xyz);
	} else if (v_top > 0.5) {
		// Flat facets on the heaped top.
		vec3 n = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
		NORMAL = n.z < 0.0 ? -n : n;
	}
	vec3 pv = (to_vessel * vec4(p, 1.0)).xyz;
	float el;
	vec3 el_rgb;
	vec4 c = cell_at(pv, el, el_rgb);
	if (el > 0.5) {
		ALBEDO = c.rgb;
		ROUGHNESS = 0.6;
		METALLIC = 0.4;
		EMISSION = el_rgb;
	} else {
		// One shade per piece, darker in the gaps between pieces. The pieces
		// are flat flakes lying at an angle, on a lattice that is turned and
		// bent so it never lines up into rows (it read as brickwork).
		vec3 q = mat3(vec3(0.80, 0.36, -0.48), vec3(-0.60, 0.48, -0.64), vec3(0.0, 0.80, 0.60)) * (pv / piece_m);
		q.y *= 2.3;
		q += 0.48 * sin(q.yzx * 1.31 + vec3(1.7, 4.2, 0.3)) + 0.22 * sin(q.zxy * 2.87 + vec3(0.9, 2.1, 5.5));
		vec3 id = floor(q);
		float rnd = hash3(id);
		vec3 f = fract(q) - 0.5;
		float gap = smoothstep(0.50, 0.34, max(abs(f.x), max(abs(f.y), abs(f.z))));
		float shade = (0.74 + 0.40 * rnd) * (0.72 + 0.28 * gap);
		// Char is matt black with a faint grey bloom of ash on a few pieces.
		float charred = smoothstep(0.30, 0.10, max(c.r, max(c.g, c.b)));
		vec3 base = c.rgb * shade;
		base = mix(base, vec3(0.17, 0.165, 0.16) * shade, charred * smoothstep(0.90, 1.0, rnd) * 0.6 * (1.0 - c.a));
		ALBEDO = base;
		ROUGHNESS = mix(0.9, 0.97, charred);
		METALLIC = 0.0;
		// Embers: each piece a little hotter or cooler, shimmering slowly.
		float g = c.a * (0.75 + 0.5 * rnd) * (0.9 + 0.1 * sin(flicker * 5.0 + rnd * 40.0));
		g = clamp(g * (0.55 + 0.45 * gap), 0.0, 1.0);
		EMISSION = incandescence(g);
	}
}

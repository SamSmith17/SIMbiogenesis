// The charge in a vessel (TC Process Lab): a cylinder whose colour comes
// from the bed's own cells. `cells` is NR wide and NZ high per element domain
// (domains stacked), rgb = what the cell is (wet wood, dry, pyrolysing, char),
// a = how hot it glows. Where the section plane cuts the charge the back
// faces seen through the cut are coloured by the point where the view ray
// crosses the plane, so the cut face is a real cross-section of the bed:
// the dry ring, the dark pyrolysis front, the glowing char round each element.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D cells : source_color, filter_linear, repeat_disable;
uniform int n_dom = 1;
uniform int nr = 8;
uniform vec4 dom[4];            // xz centre (m, vessel frame), r_in, r_out
uniform vec4 el_glow[4];        // each element: rgb, strength
uniform float bed_h = 0.3;
uniform mat4 to_vessel;         // world → vessel frame (m)
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);
uniform vec3 glow_color : source_color = vec3(1.0, 0.36, 0.08);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec4 cell_at(vec3 pv, out vec3 em) {
	em = vec3(0.0);
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
		em = el_glow[best].rgb * el_glow[best].a * 3.0;
		return vec4(mix(vec3(0.35, 0.33, 0.32), el_glow[best].rgb, el_glow[best].a), 0.0);
	}
	float u = clamp((r - D.z) / max(D.w - D.z, 1.0e-4), 0.0, 1.0);
	float v = clamp(pv.y / max(bed_h, 1.0e-4), 0.0, 1.0);
	float fn = float(nr);
	vec2 uv = vec2((u * (fn - 1.0) + 0.5) / fn, (float(best) + v) / float(n_dom));
	vec4 c = texture(cells, uv);
	em = glow_color * c.a * 2.2;
	return c;
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
	}
	vec3 pv = (to_vessel * vec4(p, 1.0)).xyz;
	vec3 em;
	vec4 c = cell_at(pv, em);
	// A little grain so chips read as chips, not paint.
	float g = fract(sin(dot(floor(pv * 260.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	ALBEDO = c.rgb * (0.82 + 0.3 * g);
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
	EMISSION = em;
}

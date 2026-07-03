shader_type spatial;

// OSM building walls: procedural lap-board siding, no texture fetches.
// Mesh contract (BuildingBuilder): UV.x = metres along the facade, UV.y =
// metres above the building base (negative = foundation skirt); COLOR.rgb =
// per-building wall tint. Gable-end fills share this surface so the siding
// courses continue up the gable.
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform float board_height_m : hint_range(0.10, 0.50) = 0.22;
uniform float seam_strength : hint_range(0.0, 1.0) = 0.45;
uniform float color_jitter : hint_range(0.0, 0.30) = 0.07;
uniform float wall_roughness : hint_range(0.3, 1.0) = 0.85;
uniform vec4 foundation_color : source_color = vec4(0.52, 0.52, 0.50, 1.0);

float hash1(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	// Backfaces (cull_disabled: floor cap, odd OSM footprints) light correctly.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	float v = UV.y;
	float band = v / board_height_m;
	float bidx = floor(band);
	float fy = fract(band);

	// Collapse the course pattern before screen-space undersampling turns it
	// into moiré (far buildings read as plain painted walls).
	float det = clamp(fwidth(band) * 2.0, 0.0, 1.0);

	// Per-board paint jitter + the undercut shadow where the course above
	// overlaps this one (top ~12% of each band), softened by derivative AA.
	float aa = fwidth(band) * 1.5 + 1e-4;
	float jitter = (hash1(bidx) - 0.5) * 2.0 * color_jitter;
	float seam = 1.0 - seam_strength * smoothstep(1.0 - 0.12 - aa, 1.0, fy);
	float boards = (1.0 + jitter) * seam;
	boards = mix(boards, 1.0, det);

	// Broad weathering wash so big facades don't read as one flat paint job.
	float wash = 1.0 + (vnoise(UV * 0.35) - 0.5) * 0.08;

	vec3 wall_rgb = COLOR.rgb * boards * wash;

	// Foundation concrete below the base line (the skirt's V is negative).
	float fnd = smoothstep(0.0, -0.02, v);
	vec3 fnd_rgb = foundation_color.rgb * (0.92 + 0.16 * vnoise(UV * 3.0));

	ALBEDO = mix(wall_rgb, fnd_rgb, fnd);
	ROUGHNESS = wall_roughness;
	METALLIC = 0.0;
	SPECULAR = 0.25;
}

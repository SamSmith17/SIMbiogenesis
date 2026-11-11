shader_type spatial;
render_mode cull_disabled, diffuse_burley;

// Garden crops on a grow bed (GardenCrops meshes in a MultiMesh per crop).
// Each plant grows from its own sowing day on the bed's clock, so nothing is
// written per plant after the bed is built:
//   INSTANCE_CUSTOM.x  sowing day (days from the bed's planting)
//   INSTANCE_CUSTOM.y  cycle length in days (sowing to clearing)
//   INSTANCE_CUSTOM.z  share of the cycle at which the plant is full size
//   INSTANCE_CUSTOM.w  a 0..1 seed
// The bed sets now_d (days since it was planted) twice a second.
// UV.x: 0 foliage, 1 fruit / flower, 2 structure. UV.y: height fraction.
// UV2.x: the share of the cycle from which a fruit shows.

uniform float now_d = 0.0;
// A cleared bed stands bare this share of each cycle before it is sown.
uniform float fallow = 0.04;
// Gentle sway (greenhouse air: a few cm at the top of a tall plant).
uniform float sway = 0.012;

varying vec3 v_col;
varying float v_part;
varying float v_h;

void vertex() {
	float sow = INSTANCE_CUSTOM.x;
	float cycle = max(INSTANCE_CUSTOM.y, 1.0);
	float mature = clamp(INSTANCE_CUSTOM.z, 0.05, 1.0);
	float seed = INSTANCE_CUSTOM.w;
	float part = UV.x;
	v_part = part;
	v_h = UV.y;
	float age = now_d - sow;
	float f = age >= 0.0 ? fract(age / cycle) : -1.0;
	// Not sown yet, or the bed is being turned: nothing there.
	bool absent = f < fallow;
	float g = smoothstep(fallow, mature, f);
	float s = mix(0.05, 1.0, g);
	vec3 col = COLOR.rgb;
	if (part > 1.5) {
		// Stakes, poles and a coppice stool stand from the first sowing on.
		s = age >= 0.0 ? 1.0 : 0.0;
		absent = age < 0.0;
	} else if (part > 0.5) {
		// Fruit and flowers swell from UV2.x and ripen over the next 15 %.
		float from = UV2.x;
		float grow = smoothstep(from, from + 0.12, f);
		float ripe = smoothstep(from + 0.06, from + 0.2, f);
		vec3 green = vec3(0.24, 0.44, 0.16);
		col = mix(green, COLOR.rgb, ripe);
		s *= grow;
		absent = absent || grow <= 0.001;
	} else {
		// The last weeks of a planting go yellow before it is cleared.
		float old_age = smoothstep(0.9, 1.0, f);
		col = mix(col, vec3(0.62, 0.56, 0.24), old_age * 0.6);
	}
	if (absent) {
		VERTEX = vec3(0.0);
	} else {
		VERTEX *= s;
		float h = UV.y * UV.y;
		VERTEX.x += sin(TIME * 1.1 + seed * 6.283) * sway * h * s;
		VERTEX.z += cos(TIME * 0.9 + seed * 4.0) * sway * h * s;
	}
	// A little per-plant variation in colour.
	v_col = col * (0.92 + 0.16 * seed);
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = v_part > 0.5 && v_part < 1.5 ? 0.42 : 0.78;
	SPECULAR = 0.35;
	// Leaves are lit through from behind a little.
	BACKLIGHT = v_part < 0.5 ? vec3(0.18, 0.24, 0.1) : vec3(0.0);
	AO = mix(0.6, 1.0, clamp(v_h * 1.6 + 0.2, 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.4;
}

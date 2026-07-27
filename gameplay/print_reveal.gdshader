shader_type spatial;
render_mode cull_disabled;

// Sliced additive-print reveal: fragments above the current print height
// (model-space Y) are discarded, so the object materializes bottom-up as
// `reveal_y` rises with the nozzle. Lower layers dry automatically as the
// tip advances; `dryness` forces a full dry (1.0 on job completion).

uniform float reveal_y = 0.0;                       // model-space Y cutoff (metres)
uniform vec3 wet_color : source_color = vec3(0.36, 0.26, 0.17);
uniform vec3 dry_color : source_color = vec3(0.68, 0.56, 0.42);
uniform float dryness = 0.0;                        // 0 wet .. 1 dry (forced)
uniform float glow_band = 0.08;                     // wet tip band thickness (m)
uniform float dry_band = 0.35;                      // distance below tip that fully dries (m)

varying float v_y;

void vertex() {
	v_y = VERTEX.y;
}

void fragment() {
	if (v_y > reveal_y + 0.0005) {
		discard;
	}
	float below = max(reveal_y - v_y, 0.0);
	// Auto-dry with depth under the tip; completion forces dryness=1.
	float auto_dry = smoothstep(0.0, max(dry_band, 0.02), below);
	float dry = clamp(max(dryness, auto_dry), 0.0, 1.0);
	vec3 col = mix(wet_color, dry_color, dry);
	ALBEDO = col;
	ROUGHNESS = mix(0.55, 0.92, dry);
	METALLIC = 0.0;
	// Hot leading edge only while still wet — extinguished when fully dry.
	float tip = (1.0 - dry) * smoothstep(glow_band, 0.0, below);
	EMISSION = wet_color * tip * 1.8;
}

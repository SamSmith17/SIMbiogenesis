shader_type spatial;
// PEAK RIPPLE: a green ring that runs out across the ground from someone who
// just hit FUCK YES!!!, as far as their contagion reaches (PeakRippleFx). One
// MultiMesh of flat unit quads, scaled to the reach; INSTANCE_CUSTOM =
// (start on the NPC cosmetic clock, strength 0..1, -, -). Additive and
// unshaded like the camp glows, and fog_disabled for the same reason (Godot
// fogs an additive quad into a coloured rectangle by day).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

global uniform float fx_time_npc;
uniform float life_s = 2.6;
uniform vec3 ring_color : source_color = vec3(0.35, 1.0, 0.45);

varying float v_age;
varying float v_strength;

void vertex() {
	v_age = (fx_time_npc - INSTANCE_CUSTOM.x) / life_s;
	v_strength = INSTANCE_CUSTOM.y;
	// Spent (or never used): collapse behind the camera.
	if (v_age < 0.0 || v_age > 1.0 || v_strength <= 0.0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	// The front runs out fast and slows (ease-out); a soft trailing fill
	// behind it shows the whole patch it reached.
	float front = 1.0 - pow(1.0 - clamp(v_age, 0.0, 1.0), 2.2);
	float ring = 1.0 - smoothstep(0.0, 0.06 + 0.05 * front, abs(r - front));
	float fill = (1.0 - smoothstep(front - 0.02, front, r)) * 0.18;
	float fade = (1.0 - v_age) * (1.0 - v_age);
	float a = (ring + fill) * fade * v_strength * step(r, 1.0);
	ALBEDO = ring_color * a * 1.6;
	ALPHA = clamp(a, 0.0, 1.0);
}

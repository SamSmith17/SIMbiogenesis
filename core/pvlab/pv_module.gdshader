// The Solar designer's module face: the cell grid drawn procedurally over
// the face's UV (u across the module's width, v along its length, 0..1 over
// the whole module), so every look is exact to the millimetre. PvLabBuilder
// .cell_uniforms() fills the uniforms from a PvLabModule spec; the layout
// maths mirrors PvLabModule.piece_rect_uv: rows from the top edge (v = 0),
// each split path band adding split_gap_mm, each folding leaf adding hinge_mm.
//
// Every fine pattern (cell gaps, busbars, fingers, thin-film scribes, the
// film's dimples) is ANALYTICALLY box-filtered: the coverage of a pulse train
// is the difference of its integral at the two ends of the pixel's footprint,
// so a pixel shows exactly the share of metal it covers. Point-sampling the
// lines (even with a soft edge) is what made the medium-distance moiré — a
// pixel a few mm wide lands on a 0.35 mm busbar or misses it, in bands. The
// footprints are taken ONCE at the top in uniform control flow (derivatives
// inside a branch are undefined at its edges). Past about a pixel per period
// the box filter still rings, so each pattern settles on its average.
//
// The glass is a clear coat over the cells. surface: 0 tempered glass with an
// AR coat, 1 textured (prismatic) glass, 2 ETFE film (dimpled), 3 PET film.
// back_side draws the REAR of a glass–glass module: the cells' grey backs
// and their rear grid. With use_overlay on (a MultiMesh with
// use_custom_data), INSTANCE_CUSTOM is an overlay colour the designer uses to
// colour strings and selections — alpha 0 leaves the module as it is.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec2 dims_mm = vec2(1052.0, 1769.0);
uniform int cols = 6;
uniform int rows = 20;
uniform vec2 piece_mm = vec2(166.0, 83.0);
uniform float gap_mm = 2.0;
uniform float split_gap_mm = 6.0;
uniform int paths = 2;
uniform float hinge_mm = 0.0;
uniform int leaves = 1;
uniform vec2 grid_mm = vec2(1006.0, 1706.0);
uniform float chamfer_mm = 8.3;
uniform int pieces = 2;
uniform bool film = false;
uniform bool metal = true;
uniform int busbars = 9;
uniform float finger_pitch_mm = 1.4;
uniform vec3 cell_color : source_color = vec3(0.035, 0.045, 0.085);
uniform vec3 sheet_color : source_color = vec3(0.88, 0.89, 0.9);
uniform vec3 hinge_color : source_color = vec3(0.05, 0.05, 0.05);
uniform vec3 grid_color : source_color = vec3(0.78, 0.8, 0.83);
uniform vec3 rear_cell_color : source_color = vec3(0.3, 0.31, 0.33);
uniform float flake = 0.0;
uniform float sheen = 0.35;
uniform float glass_roughness = 0.08;
uniform float cell_roughness = 0.45;
uniform float per_cell_tint = 0.05;
uniform int surface = 0;
uniform bool back_side = false;
uniform bool use_overlay = false;

varying vec4 v_overlay;
varying float v_seed;

void vertex() {
	v_overlay = use_overlay ? INSTANCE_CUSTOM : vec4(0.0);
	v_seed = float(INSTANCE_ID) * 0.6180339;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

// The integral from 0 to x of pulses `w` wide starting at `a` in every `p`.
float pulse_int(float x, float p, float a, float w) {
	float y = x - a;
	float k = floor(y / p);
	return k * w + clamp(y - k * p, 0.0, w);
}

// Coverage of that pulse train over the box [x − h, x + h].
float pulse_cov(float x, float p, float a, float w, float h) {
	h = max(h, 1e-4);
	float c = (pulse_int(x + h, p, a, w) - pulse_int(x - h, p, a, w)) / (2.0 * h);
	return mix(c, clamp(w / p, 0.0, 1.0), smoothstep(0.6, 1.6, 2.0 * h / p));
}

// Lines `width` wide centred in every `pitch` along `coord` (all mm); fw is
// the pixel's footprint along coord. The box is 1.5 pixels wide.
float line_mask(float coord, float pitch, float width, float fw) {
	return pulse_cov(coord, pitch, (pitch - width) * 0.5, width, fw * 0.75 + 1e-5);
}

// Row offset (mm) of row r: split bands and folding hinges before it.
float row_offset(float r) {
	float per = max(floor(float(rows) / float(max(paths, 1))), 1.0);
	float per_leaf = max(ceil(float(rows) / float(max(leaves, 1))), 1.0);
	return split_gap_mm * min(floor(r / per), float(paths - 1))
		+ hinge_mm * min(floor(r / per_leaf), float(leaves - 1));
}

// The film's relief (mm): ETFE dimples on a hexagonal 2.2 mm lattice, a fine
// pyramid texture on prismatic glass.
float relief(vec2 p) {
	if (surface == 2) {
		vec2 s = vec2(2.2, 1.905);
		vec2 a = mod(p, s) - s * 0.5;
		vec2 b = mod(p - s * 0.5, s) - s * 0.5;
		float d = min(dot(a, a), dot(b, b));
		return -0.12 * exp(-d * 1.4);
	}
	if (surface == 1) {
		vec2 q = abs(fract(p / 1.6) - 0.5);
		return -0.05 * max(q.x, q.y);
	}
	return 0.0;
}

void fragment() {
	vec2 pos = (UV - 0.5) * dims_mm;
	float total_along = grid_mm.y;
	vec2 g = vec2(pos.x + grid_mm.x * 0.5, pos.y + total_along * 0.5);
	// Footprints, in uniform control flow.
	vec2 fw = fwidth(g);
	float rel = relief(pos);
	float rel_dx = dFdx(rel);
	float rel_dy = dFdy(rel);
	vec3 dpdx = dFdx(VERTEX);
	vec3 dpdy = dFdy(VERTEX);
	float pitch_a = piece_mm.x + gap_mm;
	float pitch_l = piece_mm.y + gap_mm;
	float c = floor(g.x / pitch_a);
	// Undo the split / hinge offsets: two refinements converge (offsets only
	// grow with the row).
	float r = floor(g.y / pitch_l);
	r = clamp(floor((g.y - row_offset(r)) / pitch_l), 0.0, float(rows - 1));
	r = clamp(floor((g.y - row_offset(r)) / pitch_l), 0.0, float(rows - 1));
	vec2 local = vec2(g.x - c * pitch_a, g.y - r * pitch_l - row_offset(r));
	bool in_grid = g.x >= 0.0 && g.x <= grid_mm.x && g.y >= 0.0 && g.y <= total_along
		&& c >= 0.0 && c < float(cols);
	// How much of the pixel is cell (not gap), filtered both ways.
	float cov_x = pulse_cov(g.x, pitch_a, 0.0, piece_mm.x, fw.x * 0.75);
	float cov_y = pulse_cov(local.y + r * pitch_l, pitch_l, 0.0, piece_mm.y, fw.y * 0.75);
	float cov = cov_x * cov_y;
	// A hinge gap between folding leaves shows the case, not the backsheet.
	float per_leaf = max(ceil(float(rows) / float(max(leaves, 1))), 1.0);
	bool hinge_gap = leaves > 1 && in_grid && local.y > piece_mm.y
		&& mod(r + 1.0, per_leaf) < 0.5 && r < float(rows - 1);
	// Pseudo-square wafer corners: on the edge of the wafer each piece is cut from.
	if (in_grid && chamfer_mm > 0.0 && !film) {
		float k = mod(r, float(max(pieces, 1)));
		bool top = k < 0.5;
		bool bottom = k > float(pieces) - 1.5;
		float dx = min(local.x, piece_mm.x - local.x);
		float dy_top = local.y;
		float dy_bot = piece_mm.y - local.y;
		float lim = chamfer_mm;
		float cut = 1.0;
		if (top) cut = min(cut, clamp((dx + dy_top - lim) / max(fw.x + fw.y, 1e-4) + 0.5, 0.0, 1.0));
		if (bottom) cut = min(cut, clamp((dx + dy_bot - lim) / max(fw.x + fw.y, 1e-4) + 0.5, 0.0, 1.0));
		// Fade the chamfer into the average once a cell is a few pixels.
		float far_c = smoothstep(0.08, 0.3, max(fw.x / pitch_a, fw.y / pitch_l));
		cov *= mix(cut, 1.0 - chamfer_mm * chamfer_mm / max(piece_mm.x * piece_mm.y * float(pieces), 1.0), far_c);
	}
	// Small-scale variation fades as it drops under a pixel.
	float cell_px = max(fw.x / pitch_a, fw.y / pitch_l);
	vec3 cc = back_side ? rear_cell_color : cell_color;
	float cid = hash12(vec2(c, r) + v_seed);
	cc *= 1.0 + (cid - 0.5) * per_cell_tint * 2.0 * (1.0 - smoothstep(0.15, 0.6, cell_px));
	if (flake > 0.0 && !back_side) {
		// Cast multicrystal: grains a few mm across, each its own blue.
		vec2 q = (g + vec2(c, r) * 17.0) * 0.18;
		float fade1 = 1.0 - smoothstep(0.4, 1.4, max(fw.x, fw.y) * 0.18);
		float fade2 = 1.0 - smoothstep(0.4, 1.4, max(fw.x, fw.y) * 0.56);
		float n1 = vnoise(q);
		float n2 = mix(0.5, vnoise(q * 3.1 + 7.0), fade2);
		float grain = mix(0.5, floor(n1 * 5.0) / 5.0, fade1) * 0.65 + n2 * 0.35;
		cc = mix(cc, cc * vec3(1.6, 1.5, 1.35), grain * flake * 0.55);
		cc = mix(cc, cc * vec3(0.7, 0.75, 0.85), (1.0 - grain) * flake * 0.3);
	}
	vec3 cell_alb = cc;
	float m = 0.0;
	if (film) {
		// Thin film: the laser scribes between strips read as faint lines.
		float scribe = line_mask(local.y + r * pitch_l, pitch_l, 0.12, fw.y);
		cell_alb = mix(cell_alb, cell_alb * 1.6 + 0.02, scribe * 0.5);
	} else if (metal) {
		if (busbars > 0) {
			float bw = busbars >= 9 ? 0.35 : (busbars >= 5 ? 0.8 : 1.4);
			m = max(m, line_mask(local.x, piece_mm.x / float(busbars), bw, fw.x));
		}
		// Fingers: dimmer on the rear of a bifacial cell (a sparser grid).
		float fp = back_side ? finger_pitch_mm * 1.4 : finger_pitch_mm;
		m = max(m, line_mask(local.y, fp, 0.05, fw.y) * 0.55);
		cell_alb = mix(cell_alb, grid_color, m);
	}
	vec3 gap_alb = sheet_color;
	if (metal && busbars > 0 && !film) {
		// A glint of ribbon in the gaps between the cells of one column.
		float rib = line_mask(local.x, piece_mm.x / float(busbars), 0.8, fw.x);
		gap_alb = mix(sheet_color, grid_color, rib * (1.0 - cov_y) * 0.8);
	}
	vec3 albedo = sheet_color;
	float rough = 0.7;
	float met = 0.0;
	if (hinge_gap) {
		albedo = hinge_color;
		rough = 0.9;
	} else if (in_grid) {
		albedo = mix(gap_alb, cell_alb, cov);
		rough = mix(0.7, mix(cell_roughness, 0.35, m), cov);
		met = m * 0.8 * cov;
	}
	// The film's relief bends the normal (bump from screen derivatives), and
	// fades into a satin roughness as the dimples drop under a pixel.
	vec3 n = NORMAL;
	float coat_r = glass_roughness;
	if (surface == 1 || surface == 2) {
		float per = surface == 2 ? 2.2 : 1.6;
		float vis = 1.0 - smoothstep(0.25, 0.8, max(fw.x, fw.y) / per);
		vec3 r1 = cross(dpdy, n);
		vec3 r2 = cross(n, dpdx);
		float det = dot(dpdx, r1);
		vec3 grad = sign(det) * (rel_dx * r1 + rel_dy * r2) * 0.001;
		n = normalize(mix(n, normalize(abs(det) * n - grad), vis));
		coat_r = mix(glass_roughness + 0.12, glass_roughness, vis);
	}
	float facing = clamp(dot(n, VIEW), 0.0, 1.0);
	// Anti-reflective coatings tint a cell blue-violet at grazing angles.
	if (!back_side) {
		albedo += vec3(0.02, 0.025, 0.06) * sheen * pow(1.0 - facing, 3.0) * (in_grid ? cov : 0.0);
	}
	albedo = mix(albedo, v_overlay.rgb, v_overlay.a);
	ALBEDO = albedo;
	METALLIC = met;
	ROUGHNESS = rough;
	SPECULAR = 0.5;
	NORMAL = n;
	CLEARCOAT = surface == 3 ? 0.8 : 1.0;
	CLEARCOAT_ROUGHNESS = coat_r;
}

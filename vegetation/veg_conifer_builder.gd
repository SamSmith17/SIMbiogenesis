class_name VegConiferBuilder
extends RefCounted

## Conifer geometry (2026-10-15): a real trunk plus one curved, textured needle
## SPRAY per branch, laid out by a per-species growth habit (FORMS).
##
## It replaces the stacked crossed-card whorls every conifer shared: spruce,
## fir, cedar, hemlock and pine were the same cone of cards in different
## greens, which is why a mixed stand read as one tree. Each species now
## differs where real ones do:
##   * crown profile  — Douglas-fir a narrow spire with a rounded shoulder,
##     cedar broad at the base, hemlock slender with a NODDING leader, spruce a
##     stiff regular cone, pine an open, flat-topped irregular crown;
##   * branch angle   — upswept near the top, level or drooping below; cedar
##     branches dip and turn up at the tip (the "J"), hemlock's sag;
##   * arrangement    — whorls (pine / spruce / fir) or a spiral (cedar,
##     hemlock), with per-tree gaps and length jitter;
##   * sprays         — a flat spray plus a cross spray (the bottle-brush
##     volume) per branch; cedar and hemlock add pendant sprays that hang;
##     pine carries tufts only at the outer end of a bare branch;
##   * needles        — spray_texture() draws scale-leaf lace (cedar), short
##     flat needles (fir / hemlock / spruce) or long bundles (pine);
##   * trunk          — a tapered tube with a species flare (cedar and redwood
##     buttress, fluted near the ground).
## A seed (the style's `<family>_variant_seed`, stepped per instance variant by
## VegetationRuntime) re-rolls the jitter so neighbouring trees differ.
##
## Output is plain arrays in METRES; VegetationCardFactory normalizes the size
## to the style's exact height/crown and assigns the bark + foliage materials.

const MAX_BRANCHES := 150
## Lowest any spray point may sit (m above the tree's foot).
const GROUND_CLEAR_M := 0.35
const SEGMENTS := 4

## Growth habit per species. Missing keys fall back to FORMS["pine"]'s.
##   profile_p    crown radius r(t) = R * (1 - t)^p * (1 + bulge sin(pi t)),
##                t = 0 at the crown base, 1 at the top
##   tilt0/tilt1  branch angle BELOW horizontal at the crown base / top (deg)
##   sag          gravity bow along the branch (fraction of its length)
##   curl         upturn at the outer end (the cedar J)
##   spacing_m    tier spacing on a 30 m tree (scaled with height)
##   per_tier     branches per tier; whorled = all at one height, else spiral
##   spray_w      spray width as a fraction of branch length
##   cross        the cross spray's width relative to the flat one
##   pendants     hanging sprays per branch
##   laterals     side sprays forking off each branch (fill the gaps between
##                tiers so a crown reads as a mass, not a ladder of fronds)
##   bare         inner fraction of the branch with no foliage (pine)
##   jitter       length / angle randomness; gaps = chance a branch is missing
##   leader_nod   how far the top bends over (hemlock)
##   flare        trunk radius at the ground relative to breast height
##   flute        trunk fluting near the ground
##   needle       spray texture style: "needle" | "scale" | "long"
const FORMS := {
	"pine": {"profile_p": 0.45, "bulge": 0.18, "tilt0": -2.0, "tilt1": -40.0,
		"sag": 0.10, "curl": 0.30, "spacing_m": 1.0, "per_tier": 4, "whorled": true,
		"spray_w": 0.42, "cross": 1.0, "pendants": 0, "bare": 0.4, "jitter": 0.35,
		"gaps": 0.18, "leader_nod": 0.0, "flare": 1.15, "flute": 0.0,
		"needle": "long", "laterals": 2},
	"spruce": {"profile_p": 1.0, "bulge": 0.0, "tilt0": 12.0, "tilt1": -30.0,
		"sag": 0.22, "curl": 0.18, "spacing_m": 0.55, "per_tier": 5, "whorled": true,
		"spray_w": 0.36, "cross": 0.85, "pendants": 1, "bare": 0.08, "jitter": 0.08,
		"gaps": 0.03, "leader_nod": 0.0, "flare": 1.2, "flute": 0.0,
		"needle": "needle", "laterals": 3},
	"douglas_fir": {"profile_p": 0.82, "bulge": 0.14, "tilt0": 18.0, "tilt1": -38.0,
		"sag": 0.32, "curl": 0.28, "spacing_m": 0.62, "per_tier": 5, "whorled": true,
		"spray_w": 0.42, "cross": 0.75, "pendants": 1, "bare": 0.10, "jitter": 0.2,
		"gaps": 0.08, "leader_nod": 0.0, "flare": 1.35, "flute": 0.0,
		"needle": "needle", "laterals": 2},
	"fir": {"profile_p": 1.1, "bulge": 0.0, "tilt0": 4.0, "tilt1": -45.0,
		"sag": 0.12, "curl": 0.12, "spacing_m": 0.5, "per_tier": 5, "whorled": true,
		"spray_w": 0.38, "cross": 0.9, "pendants": 0, "bare": 0.06, "jitter": 0.07,
		"gaps": 0.02, "leader_nod": 0.0, "flare": 1.15, "flute": 0.0,
		"needle": "needle", "laterals": 2},
	"cedar": {"profile_p": 0.72, "bulge": 0.22, "tilt0": 32.0, "tilt1": -8.0,
		"sag": 0.42, "curl": 0.62, "spacing_m": 0.5, "per_tier": 3, "whorled": false,
		"spray_w": 0.55, "cross": 0.45, "pendants": 3, "bare": 0.06, "jitter": 0.24,
		"gaps": 0.05, "leader_nod": 0.15, "flare": 1.9, "flute": 0.10,
		"needle": "scale", "laterals": 1},
	"hemlock": {"profile_p": 0.8, "bulge": 0.10, "tilt0": 26.0, "tilt1": 2.0,
		"sag": 0.52, "curl": 0.10, "spacing_m": 0.5, "per_tier": 3, "whorled": false,
		"spray_w": 0.50, "cross": 0.55, "pendants": 2, "bare": 0.06, "jitter": 0.2,
		"gaps": 0.05, "leader_nod": 0.85, "flare": 1.25, "flute": 0.0,
		"needle": "needle", "laterals": 1},
	"redwood": {"profile_p": 0.55, "bulge": 0.10, "tilt0": 22.0, "tilt1": -12.0,
		"sag": 0.3, "curl": 0.35, "spacing_m": 0.7, "per_tier": 3, "whorled": false,
		"spray_w": 0.48, "cross": 0.6, "pendants": 2, "bare": 0.25, "jitter": 0.3,
		"gaps": 0.12, "leader_nod": 0.0, "flare": 1.8, "flute": 0.12,
		"needle": "needle", "laterals": 1},
}


static func form_for(species: String) -> Dictionary:
	var base: Dictionary = FORMS["pine"]
	var f: Dictionary = FORMS.get(species, base)
	if f == base:
		return base
	var out := base.duplicate()
	out.merge(f, true)
	return out


## spec: VegetationCardFactory._pine_spec (height_m, crown_m, trunk_r,
## crown_base 0..1, droop, branchiness). Returns
## {"trunk": [verts, uvs, normals, indices], "foliage": [...]} in metres.
static func build(spec: Dictionary, form: Dictionary, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var h := float(spec.get("height_m", 17.0))
	var crown_r := float(spec.get("crown_m", 7.0)) * 0.5
	var trunk_r := maxf(float(spec.get("trunk_r", 0.2)), 0.04)
	var base_t := clampf(float(spec.get("crown_base", 0.08)), 0.0, 0.85)
	# The style's droop / branchiness macros nudge the habit; 0.12 / 0.5 are
	# the neutral values (the defaults), so an untouched style is the form.
	var droop_k := clampf(float(spec.get("droop", 0.12)) - 0.12, -0.12, 0.88)
	var branchy := clampf(float(spec.get("branchiness", 0.5)), 0.0, 1.0)
	# Tune-look sliders (each neutral at its default): whorls = how many
	# branch tiers against what branchiness derives, whorl gap = tier spacing,
	# bough size = branch length, jitter / spin = irregularity, crookedness =
	# trunk lean, foliage = spray fullness, taper = trunk profile.
	var tier_mul := clampf(float(spec.get("whorl_count", spec.get("whorl_default", 8.0)))
		/ maxf(float(spec.get("whorl_default", 8.0)), 1.0), 0.3, 3.0)
	var gap_mul := clampf(float(spec.get("whorl_spacing", 1.0)), 0.3, 2.0)
	var bough := clampf(float(spec.get("bough_scale", 1.0)), 0.3, 2.0)
	var jitter_add := clampf(float(spec.get("whorl_jitter", 0.08)) - 0.08, -0.08, 0.6)
	var spin := clampf(float(spec.get("whorl_variation", 0.32)) / 0.32, 0.0, 3.2)
	var crook := clampf(float(spec.get("crookedness", 0.2)), 0.0, 1.0)
	var fill := lerpf(0.75, 1.3, clampf(float(spec.get("foliage_density", 0.6)), 0.0, 1.0)) \
		/ lerpf(0.75, 1.3, 0.6)
	var taper := clampf(float(spec.get("trunk_taper", 0.38)), 0.05, 1.0)
	var sag := clampf(float(form["sag"]) + droop_k * 0.6, 0.0, 1.0)
	var tilt0 := float(form["tilt0"]) + droop_k * 30.0
	var tilt1 := float(form["tilt1"]) + droop_k * 15.0

	var tv := PackedVector3Array()
	var tu := PackedVector2Array()
	var tn := PackedVector3Array()
	var ti := PackedInt32Array()
	_add_trunk(tv, tu, tn, ti, trunk_r, h, float(form["flare"]), float(form["flute"]), rng,
		taper, crook)

	var fv := PackedVector3Array()
	var fu := PackedVector2Array()
	var fn := PackedVector3Array()
	var fi := PackedInt32Array()
	var y0 := h * base_t
	var y1 := h * 0.985
	var crown_len := maxf(y1 - y0, 0.5)
	var spacing := float(form["spacing_m"]) * clampf(h / 30.0, 0.35, 1.6) \
		* lerpf(1.35, 0.75, branchy) * gap_mul / tier_mul
	var per_tier := int(form["per_tier"])
	var tiers := maxi(int(crown_len / spacing), 4)
	while tiers * per_tier > MAX_BRANCHES and tiers > 4:
		tiers -= 1
	var whorled := bool(form["whorled"])
	var jitter := clampf(float(form["jitter"]) + jitter_add + (crook - 0.2) * 0.25, 0.0, 0.9)
	var gaps := float(form["gaps"])
	var golden := PI * (3.0 - sqrt(5.0))
	var k := 0
	for tier in tiers:
		var t := (float(tier) + 0.5) / float(tiers)
		for b in per_tier:
			k += 1
			if rng.randf() < gaps:
				continue
			var tt := t
			if not whorled:
				tt = clampf(t + (float(b) / float(per_tier) - 0.5) / float(tiers)
					+ rng.randf_range(-0.3, 0.3) / float(tiers), 0.0, 1.0)
			var y := y0 + crown_len * tt
			var az := (TAU * float(b) / float(per_tier) + float(tier) * 0.6) if whorled \
				else float(k) * golden
			az += rng.randf_range(-0.35, 0.35) * (1.0 + jitter) * spin
			var env := envelope_radius(tt, crown_r, form)
			var length := maxf(env * bough * rng.randf_range(1.0 - jitter * 0.6,
				1.0 + jitter * 0.25), 0.25)
			var tilt := lerpf(tilt0, tilt1, tt) + rng.randf_range(-12.0, 12.0) * jitter
			_add_branch(fv, fu, fn, fi, tv, tu, tn, ti, Vector3(0.0, y, 0.0), az, length,
				tilt, sag * (1.0 - tt * 0.5), float(form["curl"]), form, trunk_r, h, rng, fill)
	_add_leader(fv, fu, fn, fi, h, crown_r, float(form["leader_nod"]), form, rng)
	return {"trunk": [tv, tu, tn, ti], "foliage": [fv, fu, fn, fi]}


## The crown's radius at fraction t (0 = crown base, 1 = top).
static func envelope_radius(t: float, crown_r: float, form: Dictionary) -> float:
	var p := float(form["profile_p"])
	var bulge := float(form["bulge"])
	return crown_r * pow(maxf(1.0 - t, 0.0), p) * (1.0 + bulge * sin(PI * t)) \
		/ (1.0 + bulge * 0.5)


static func _branch_point(origin: Vector3, dir: Vector3, length: float, tilt_deg: float,
		sag: float, curl: float, s: float) -> Vector3:
	var tr := deg_to_rad(tilt_deg)
	var p := origin + dir * (length * s * cos(tr)) - Vector3.UP * (length * s * sin(tr))
	p -= Vector3.UP * (sag * length * s * s)
	var c := maxf(s - 0.5, 0.0)
	p += Vector3.UP * (curl * length * c * c * 2.2)
	# A low bough that sags rests ON the ground — never through it.
	p.y = maxf(p.y, GROUND_CLEAR_M)
	return p


static func _add_branch(fv: PackedVector3Array, fu: PackedVector2Array,
		fn: PackedVector3Array, fi: PackedInt32Array,
		tv: PackedVector3Array, tu: PackedVector2Array,
		tn: PackedVector3Array, ti: PackedInt32Array,
		origin: Vector3, az: float, length: float, tilt: float, sag: float, curl: float,
		form: Dictionary, trunk_r: float, h: float, rng: RandomNumberGenerator,
		fill: float = 1.0) -> void:
	var dir := Vector3(cos(az), 0.0, sin(az))
	var bare := float(form["bare"])
	var spray_w := float(form["spray_w"]) * length * fill
	var cross := float(form["cross"])
	var roll := rng.randf_range(-0.35, 0.35)
	# A bare inner branch (pine, redwood): bark, so the open crown shows limbs.
	if bare > 0.15:
		var a := origin + dir * trunk_r * 0.5
		var b := _branch_point(origin, dir, length, tilt, sag, curl, bare)
		var w := clampf(trunk_r * 0.22, 0.03, 0.18)
		VegetationCardFactory._add_branch_segment(tv, tu, tn, ti, a, b, w, w * 0.5)
	var pts: Array[Vector3] = []
	for i in SEGMENTS + 1:
		var s := lerpf(bare, 1.0, float(i) / float(SEGMENTS))
		pts.append(_branch_point(origin, dir, length, tilt, sag, curl, s))
	var radial := dir
	_add_ribbon(fv, fu, fn, fi, pts, spray_w, radial, roll, false)
	if cross > 0.05:
		_add_ribbon(fv, fu, fn, fi, pts, spray_w * cross, radial, roll, true)
	var laterals := int(form.get("laterals", 0))
	for li in laterals:
		var s0 := lerpf(maxf(bare, 0.3), 0.8, (float(li) + 0.5) / float(laterals))
		var at0 := _branch_point(origin, dir, length, tilt, sag, curl, s0)
		var side_sign := 1.0 if (li % 2 == 0) else -1.0
		var ldir := dir.rotated(Vector3.UP, side_sign * rng.randf_range(0.5, 0.9))
		var llen := length * (0.2 + 0.55 * (1.0 - s0)) * rng.randf_range(0.8, 1.15)
		var lp: Array[Vector3] = []
		for i in 4:
			var t := float(i) / 3.0
			var q := at0 + ldir * llen * t - Vector3.UP * (sag * llen * t * t * 0.7)
			q.y = maxf(q.y, GROUND_CLEAR_M)
			lp.append(q)
		_add_ribbon(fv, fu, fn, fi, lp, spray_w * 0.7, ldir, rng.randf_range(-0.4, 0.4), false)
		if cross > 0.05:
			_add_ribbon(fv, fu, fn, fi, lp, spray_w * 0.7 * cross, ldir, 0.0, true)
	var pendants := int(form["pendants"])
	for pi in pendants:
		var s := lerpf(0.35, 0.9, (float(pi) + 0.5) / float(pendants))
		var at := _branch_point(origin, dir, length, tilt, sag, curl, s)
		var hang := length * rng.randf_range(0.22, 0.38) * (0.6 + sag)
		var down := (-Vector3.UP * 0.85 + dir * 0.45).normalized()
		hang = minf(hang, maxf(at.y - GROUND_CLEAR_M, 0.0) / 0.85)
		if hang < 0.3:
			continue
		var p2: Array[Vector3] = [at, at + down * hang * 0.5, at + down * hang]
		_add_ribbon(fv, fu, fn, fi, p2, spray_w * 0.55, radial, rng.randf_range(-0.6, 0.6), true)
	var _unused := h


## A spray: a strip of quads along `pts`, U along the branch (0 at the trunk),
## V across it (0 on the upper / outer edge — the foliage shader lights V=0 as
## the top of a card). `vertical` = the cross spray standing on edge.
static func _add_ribbon(fv: PackedVector3Array, fu: PackedVector2Array,
		fn: PackedVector3Array, fi: PackedInt32Array, pts: Array[Vector3],
		width: float, radial: Vector3, roll: float, vertical: bool) -> void:
	var n := pts.size()
	if n < 2:
		return
	var base := fv.size()
	for i in n:
		var tangent := (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var side := tangent.cross(Vector3.UP)
		if side.length_squared() < 1e-6:
			side = Vector3.RIGHT
		side = side.normalized().rotated(tangent, roll)
		if vertical:
			side = tangent.cross(side).normalized()
			if side.y < 0.0:
				side = -side
		var s := float(i) / float(n - 1)
		# Narrow at the trunk and the tip, widest past the middle.
		var w := width * (0.30 + 0.70 * pow(sin(PI * clampf(s * 0.92 + 0.06, 0.0, 1.0)), 0.6))
		var e0 := pts[i] + side * w * 0.5
		var e1 := pts[i] - side * w * 0.5
		# An edge-on spray's lower edge must not dip under the ground either.
		e0.y = maxf(e0.y, 0.05)
		e1.y = maxf(e1.y, 0.05)
		fv.append(e0)
		fv.append(e1)
		fu.append(Vector2(s, 0.0))
		fu.append(Vector2(s, 1.0))
		# Normals bent outward and up: a crown lit as a volume, not as flat
		# cards edge-on to the sun.
		var face := side.cross(tangent).normalized()
		if face.y < 0.0:
			face = -face
		var nrm := (face * 0.45 + radial * 0.45 + Vector3.UP * 0.35).normalized()
		fn.append(nrm)
		fn.append(nrm)
	for i in n - 1:
		var a := base + i * 2
		fi.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])


## The leader: an upright spray at the top, nodding over on hemlock.
static func _add_leader(fv: PackedVector3Array, fu: PackedVector2Array,
		fn: PackedVector3Array, fi: PackedInt32Array, h: float, crown_r: float,
		nod: float, form: Dictionary, rng: RandomNumberGenerator) -> void:
	var len := clampf(h * 0.09, 0.6, 3.5)
	var bend_dir := Vector3(cos(rng.randf() * TAU), 0.0, sin(rng.randf() * TAU))
	var pts: Array[Vector3] = []
	for i in 4:
		var s := float(i) / 3.0
		var p := Vector3(0.0, h - len + len * s, 0.0)
		p += bend_dir * (nod * len * 0.7 * s * s)
		p.y -= nod * len * 0.45 * s * s
		pts.append(p)
	var w := clampf(crown_r * 0.18, 0.25, 1.4) * float(form["spray_w"]) / 0.4
	_add_ribbon(fv, fu, fn, fi, pts, w, bend_dir, 0.0, true)
	_add_ribbon(fv, fu, fn, fi, pts, w, bend_dir, PI * 0.5, true)


## Tapered trunk tube from the ground to just under the top, flaring (and on
## cedar fluting) near the ground. UVs ping-pong inside the bark texture's
## opaque band, like the deciduous trunk.
static func _add_trunk(tv: PackedVector3Array, tu: PackedVector2Array,
		tn: PackedVector3Array, ti: PackedInt32Array, r: float, h: float,
		flare: float, flute: float, rng: RandomNumberGenerator,
		taper: float = 0.38, crook: float = 0.2) -> void:
	var sides := 8
	var rings: Array[float] = [0.0, 0.015, 0.04, 0.09, 0.2, 0.4, 0.65, 0.85, 0.97]
	var start := tv.size()
	var lean := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)) \
		* h * lerpf(0.002, 0.04, crook)
	# Taper: 0.38 (the default) is the natural cone; up toward 1 the stem
	# stays thick to the top, down toward 0 it whips thin early.
	var keep := clampf((taper - 0.38) / 0.62, 0.0, 1.0)
	var exp_t := 0.9 + maxf(0.38 - taper, 0.0) * 2.5
	for t in rings:
		var fl := 1.0 + (flare - 1.0) * pow(clampf(1.0 - t / 0.09, 0.0, 1.0), 2.0)
		var rr := r * lerpf(pow(1.0 - t, exp_t), 1.0 - 0.6 * t, keep) * fl + 0.02
		var y := h * t
		for i in sides + 1:
			var az := TAU * float(i) / float(sides)
			var fluting := 1.0 + flute * sin(az * 5.0) * clampf(1.0 - t / 0.12, 0.0, 1.0)
			var dir := Vector3(cos(az), 0.0, sin(az))
			tv.append(dir * rr * fluting + Vector3(0.0, y, 0.0) + lean * t * t)
			tn.append((dir + Vector3.UP * 0.4).normalized())
			VegetationCardFactory.verts_uv_pingpong(tu, az, 1.0 - t)
	var stride := sides + 1
	for ring in rings.size() - 1:
		for i in sides:
			var a := start + ring * stride + i
			ti.append_array([a, a + stride, a + 1, a + 1, a + stride, a + stride + 1])


# --- needle sprays ---------------------------------------------------------

## The spray texture: U (x) along the branch from the trunk (0) to the tip (1),
## V (y) across with the twig on the centre line. Styles:
##   "needle" — side shoots off the twig, short flat needles off every shoot
##              (fir, hemlock, spruce)
##   "scale"  — cedar's lace: twice-divided flat sprays drawn as thick strokes
##   "long"   — pine: bare twig, long needle bundles fanning at the outer end
static func spray_texture(spec: Dictionary, style: String, seed: int) -> ImageTexture:
	var w := 256
	var hgt := 128
	var img := Image.create(w, hgt, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var top: Color = spec.get("top", Color(0.1, 0.25, 0.12))
	var bottom: Color = spec.get("bottom", Color(0.08, 0.16, 0.08))
	var hi: Color = spec.get("highlight", Color(0.2, 0.35, 0.16))
	var twig := Color(0.20, 0.14, 0.09)
	var cy := float(hgt) * 0.5
	# The spray must be mostly SOLID: a texel-thin needle disappears in the
	# mipmaps and under the foliage shader's alpha cut (the first version drew
	# 1 px needles and every conifer read as a bare pole). Each shoot is a
	# filled, feather-shaped lobe with a serrated edge; needle strokes only add
	# the fringe.
	match style:
		"scale":
			# Cedar: broad flat lace — fat lobes, each with side lobes.
			var shoots := 9
			for i in shoots:
				var u := (float(i) + 0.5) / float(shoots) * float(w - 10)
				for sgn in [-1.0, 1.0]:
					var reach := cy * 0.95 * _spray_env(u / float(w))
					var a := Vector2(u, cy)
					var b := a + Vector2(reach * 0.6, sgn * reach * 0.92)
					_lobe(img, a, b, reach * 0.46, _needle_col(top, bottom, hi, rng, sgn), rng)
					for j in 3:
						var f := (float(j) + 1.0) / 4.0
						var p := a.lerp(b, f)
						var lob := reach * 0.36 * (1.0 - f * 0.4)
						_lobe(img, p, p + Vector2(lob, sgn * lob * 0.25), lob * 0.32,
							_needle_col(top, bottom, hi, rng, sgn), rng)
		"long":
			# Pine: dense brushes of long needles toward the branch end.
			for bundle in 10:
				var u := lerpf(0.36, 0.97, float(bundle) / 9.0) * float(w)
				var origin := Vector2(u, cy + rng.randf_range(-3, 3))
				for n in 22:
					var ang := rng.randf_range(-1.35, 1.35)
					var ln := rng.randf_range(0.55, 0.98) * cy
					var tip := origin + Vector2(cos(ang) * ln * 0.55 + ln * 0.25, sin(ang) * ln)
					_stroke(img, origin, tip, 2.6,
						_needle_col(top, bottom, hi, rng, signf(sin(ang))), 1.0)
		_:
			# Fir / hemlock / spruce: a flat frond of overlapping feathers.
			var shoots2 := 11
			for i in shoots2:
				var u := (float(i) + 0.5) / float(shoots2) * float(w - 8)
				for sgn in [-1.0, 1.0]:
					var reach := cy * 0.93 * _spray_env(u / float(w))
					var a := Vector2(u, cy)
					var b := a + Vector2(reach * 0.5, sgn * reach * 0.95)
					var c := _needle_col(top, bottom, hi, rng, sgn)
					_lobe(img, a, b, reach * 0.44, c, rng)
					# Needle fringe off the lobe's outer edge.
					var steps := int(reach / 3.5)
					for j in steps:
						var f := (float(j) + 0.5) / float(steps)
						var p := a.lerp(b, f)
						var nl := 7.0 * (1.0 - f * 0.35)
						_stroke(img, p, p + Vector2(nl * 0.9, sgn * nl * 0.7), 2.0, c, 1.0)
						_stroke(img, p, p + Vector2(nl * 0.9, -sgn * nl * 0.3), 2.0, c, 1.0)
	# Main twig over the foliage.
	_stroke(img, Vector2(0, cy), Vector2(w - 4, cy + rng.randf_range(-3, 3)), 2.4, twig, 1.0)
	# Colour bleed + coverage-preserving mips (shared with the broadleaf
	# sprays): plain mipmaps averaged in the black of empty texels.
	return ImageTexture.create_from_image(
		VegBroadleafBuilder.finalize_cutout(img, VegBroadleafBuilder.ALPHA_CUT))


## A filled feather from `a` to `b`, widest a third of the way out, `width`
## px at its widest, with a serrated (noisy) edge.
static func _lobe(img: Image, a: Vector2, b: Vector2, width: float, col: Color,
		rng: RandomNumberGenerator) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var pad := width + 2.0
	var minx := clampi(int(minf(a.x, b.x) - pad), 0, w - 1)
	var maxx := clampi(int(maxf(a.x, b.x) + pad), 0, w - 1)
	var miny := clampi(int(minf(a.y, b.y) - pad), 0, h - 1)
	var maxy := clampi(int(maxf(a.y, b.y) + pad), 0, h - 1)
	var ab := b - a
	var l2 := maxf(ab.length_squared(), 0.0001)
	var phase := rng.randf() * TAU
	var shade := rng.randf_range(-0.06, 0.06)
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			# Half-width profile: thin at the base, full at ~1/3, point at the tip.
			var prof := sin(PI * clampf(t * 0.85 + 0.12, 0.0, 1.0)) * (1.0 - t * 0.35)
			var serr := 0.82 + 0.18 * sin(t * 38.0 + phase)
			var hw := width * 0.5 * prof * serr
			var cov := clampf(hw - d + 0.5, 0.0, 1.0)
			if cov <= 0.0:
				continue
			# Lit toward the outer edge, darker along the midrib.
			var cc := col.lerp(col.darkened(0.25), clampf(1.0 - d / maxf(hw, 0.5), 0.0, 1.0) * 0.5)
			cc = cc.lightened(shade) if shade > 0.0 else cc.darkened(-shade)
			var cur := img.get_pixel(x, y)
			var outc := Color(lerpf(cur.r, cc.r, cov), lerpf(cur.g, cc.g, cov),
				lerpf(cur.b, cc.b, cov), maxf(cur.a, cov))
			if cur.a <= 0.0:
				outc = Color(cc.r, cc.g, cc.b, cov)
			img.set_pixel(x, y, outc)


## Spray outline along the branch: narrow at the trunk, full past the middle,
## rounded at the tip.
static func _spray_env(u: float) -> float:
	return clampf(0.35 + 0.65 * sin(PI * clampf(u * 0.9 + 0.08, 0.0, 1.0)), 0.0, 1.0)


static func _needle_col(top: Color, bottom: Color, hi: Color, rng: RandomNumberGenerator,
		side: float) -> Color:
	# Upper side (sgn -1 = toward V 0, the lit edge) lighter; a few bright
	# new-growth tips.
	var c := bottom.lerp(top, 0.55 + (0.35 if side < 0.0 else -0.1) + rng.randf_range(-0.12, 0.12))
	if rng.randf() < 0.12:
		c = c.lerp(hi, 0.6)
	c.a = 1.0
	return c


## A soft-edged line of `width` px.
static func _stroke(img: Image, a: Vector2, b: Vector2, width: float, col: Color,
		alpha: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var minx := clampi(int(minf(a.x, b.x) - width - 1.0), 0, w - 1)
	var maxx := clampi(int(maxf(a.x, b.x) + width + 1.0), 0, w - 1)
	var miny := clampi(int(minf(a.y, b.y) - width - 1.0), 0, h - 1)
	var maxy := clampi(int(maxf(a.y, b.y) + width + 1.0), 0, h - 1)
	var ab := b - a
	var l2 := maxf(ab.length_squared(), 0.0001)
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			var cov := clampf(width * 0.5 + 0.5 - d, 0.0, 1.0) * alpha
			if cov <= 0.0:
				continue
			var cur := img.get_pixel(x, y)
			var outc := col
			outc.a = maxf(cur.a, cov)
			if cur.a > 0.0:
				outc = Color(lerpf(cur.r, col.r, cov), lerpf(cur.g, col.g, cov),
					lerpf(cur.b, col.b, cov), outc.a)
			img.set_pixel(x, y, outc)

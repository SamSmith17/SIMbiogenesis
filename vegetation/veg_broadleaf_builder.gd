class_name VegBroadleafBuilder
extends RefCounted

## Broadleaf foliage (2026-10-15): leaf SPRAYS on the real twigs of the
## space-colonization skeleton, replacing the lumpy ellipsoid leaf shells.
##
## The shells were the "blobby" broadleaf: every crown was a stack of balls
## with a leaf pattern painted on, so a maple, an alder and a birch differed
## only in colour and outline. Real crowns read the way they do because the
## leaves hang off twigs:
##   * the SILHOUETTE is ragged — clumps on the twig ends, sky between them;
##   * the limbs SHOW through the gaps, bare inside the leafy shell;
##   * the LEAF is the species — a bigleaf maple's dinner-plate palms, an
##     alder's toothed ovals, a birch's small triangles on hanging twigs.
##
## Each spray is a short bent strip (two quads) carrying a texture of one
## twig with that species' leaves (leaf_texture), placed along the outer
## twigs (fewer inward: scaffold limbs stay bare) and fanned to both sides,
## facing the sky more or less depending on the species. Per-vertex COLOR
## tells the foliage shader (spray_mode) what UV.y tells it for cards:
##   r = depth into the crown (0 outer leaves .. 1 deep inside) — shading
##   g = height fraction of the tree — wind
##   b = a per-spray random — leaf fall keys on it so sprays drop unevenly
##
## Output arrays are in the skeleton's internal frame; the card factory
## normalizes them together with the trunk to the exact authored size.

const MAX_SPRAYS := 1800
const MIN_SPRAYS := 120
## Every form's spray_m is a real branchlet length; the card carries it
## and its leaves at this multiple, so one card is a twig with its side
## shoots — a crown needs fewer, fuller cards than single-shoot sprays.
const SPRAY_SCALE := 1.45
## The foliage shader's alpha cut (scissor) that the mip chain must keep.
const ALPHA_CUT := 0.4
const TEX_W := 256
const TEX_H := 160

## Per-species habit. Missing keys come from FORMS["deciduous"].
##   leaf       leaf shape the texture draws (see _half_width / _palmate)
##   leaf_cm    real leaf length (decides how many leaves fit on a spray)
##   spray_m    spray length on a 12 m wide crown (scaled with the crown)
##   aspect     spray width / length
##   fill       how much leaf area the crown carries (1 = a dense crown)
##   shell      how far inward leaves reach: max twigs-beyond (pipe tip count)
##              of a branch that still carries sprays
##   face_up    how much the leaves turn to the sky (beech flat layers 0.9,
##              birch / aspen hanging 0.35)
##   droop      twigs hang (birch, willow) 0 .. 1
##   upturn     twigs lift at the end 0 .. 1
##   clump      share of sprays bunched on twig ends instead of along them
##   under      underside colour lift (aspen / cottonwood / olive silver)
##   gloss      leaf sheen highlight in the texture (glossy evergreens)
##   leaflets   pinnate: leaflets per compound leaf
const FORMS := {
	"deciduous": {"leaf": "ovate", "leaf_cm": 9.0, "spray_m": 0.95, "aspect": 0.62,
		"fill": 1.0, "shell": 6.0, "face_up": 0.6, "droop": 0.12, "upturn": 0.15,
		"clump": 0.35, "under": 0.0, "gloss": 0.0, "leaflets": 0},
	# Bigleaf maple: the biggest leaves of any maple (15-30 cm, five deep
	# lobes) on stout twigs, in heavy clumps, a little floppy.
	"maple": {"leaf": "palmate", "leaf_cm": 22.0, "spray_m": 1.25, "aspect": 0.7,
		"fill": 1.05, "shell": 7.0, "face_up": 0.62, "droop": 0.22, "upturn": 0.05,
		"clump": 0.55},
	# Red alder: dark, doubly toothed ovals 7-15 cm, a fairly open crown.
	"alder": {"leaf": "serrate", "leaf_cm": 11.0, "spray_m": 0.9, "aspect": 0.62,
		"fill": 0.85, "shell": 5.0, "face_up": 0.55, "droop": 0.12, "upturn": 0.18,
		"clump": 0.3},
	# Birch: small triangular toothed leaves on slender HANGING twigs.
	"birch": {"leaf": "triangular", "leaf_cm": 6.0, "spray_m": 0.85, "aspect": 0.45,
		"fill": 0.8, "shell": 4.0, "face_up": 0.35, "droop": 0.7, "upturn": 0.0,
		"clump": 0.2},
	# Quaking aspen: round leaves on flat stalks, pale undersides, a narrow
	# short crown high on a white trunk.
	"aspen": {"leaf": "round", "leaf_cm": 6.0, "spray_m": 0.7, "aspect": 0.6,
		"fill": 0.85, "shell": 4.0, "face_up": 0.35, "droop": 0.3, "upturn": 0.1,
		"clump": 0.25, "under": 0.35},
	# Black cottonwood: glossy deltoid leaves, silver beneath, on heavy
	# ascending limbs with an open, ragged top.
	"cottonwood": {"leaf": "deltoid", "leaf_cm": 11.0, "spray_m": 1.05, "aspect": 0.6,
		"fill": 0.85, "shell": 5.0, "face_up": 0.5, "droop": 0.1, "upturn": 0.3,
		"clump": 0.5, "under": 0.4, "gloss": 0.25},
	# Beech: flat layered sprays of neat elliptic leaves — a dense shady dome.
	"beech": {"leaf": "elliptic", "leaf_cm": 9.0, "spray_m": 1.0, "aspect": 0.66,
		"fill": 1.2, "shell": 9.0, "face_up": 0.9, "droop": 0.15, "upturn": 0.0,
		"clump": 0.25, "gloss": 0.15},
	# Sweet chestnut: long toothed lances 15-25 cm.
	"chestnut": {"leaf": "lance_serrate", "leaf_cm": 20.0, "spray_m": 1.15, "aspect": 0.62,
		"fill": 1.0, "shell": 7.0, "face_up": 0.6, "droop": 0.15, "upturn": 0.1,
		"clump": 0.45, "gloss": 0.15},
	# Walnut: big compound leaves, few twigs — an airy open crown.
	"walnut": {"leaf": "pinnate", "leaf_cm": 40.0, "spray_m": 1.3, "aspect": 0.75,
		"fill": 0.8, "shell": 5.0, "face_up": 0.6, "droop": 0.18, "upturn": 0.05,
		"clump": 0.65, "leaflets": 5},
	# Oregon white oak (Garry oak): deeply lobed leathery leaves in tight
	# tufts on the ends of crooked limbs.
	"oak": {"leaf": "lobed", "leaf_cm": 11.0, "spray_m": 0.9, "aspect": 0.65,
		"fill": 0.95, "shell": 6.0, "face_up": 0.6, "droop": 0.08, "upturn": 0.12,
		"clump": 0.7, "gloss": 0.1},
	"apple": {"leaf": "ovate", "leaf_cm": 8.0, "spray_m": 0.7, "aspect": 0.65,
		"fill": 1.0, "shell": 6.0, "face_up": 0.6, "droop": 0.2, "upturn": 0.1,
		"clump": 0.5},
	"pear": {"leaf": "elliptic", "leaf_cm": 7.0, "spray_m": 0.7, "aspect": 0.6,
		"fill": 1.0, "shell": 6.0, "face_up": 0.55, "droop": 0.1, "upturn": 0.25,
		"clump": 0.45, "gloss": 0.35},
	"orange": {"leaf": "elliptic", "leaf_cm": 9.0, "spray_m": 0.65, "aspect": 0.7,
		"fill": 1.35, "shell": 10.0, "face_up": 0.6, "droop": 0.05, "upturn": 0.1,
		"clump": 0.3, "gloss": 0.55},
	"avocado": {"leaf": "elliptic", "leaf_cm": 16.0, "spray_m": 0.95, "aspect": 0.7,
		"fill": 1.3, "shell": 9.0, "face_up": 0.55, "droop": 0.15, "upturn": 0.05,
		"clump": 0.4, "gloss": 0.45},
	"mango": {"leaf": "lance", "leaf_cm": 22.0, "spray_m": 1.0, "aspect": 0.7,
		"fill": 1.3, "shell": 9.0, "face_up": 0.5, "droop": 0.3, "upturn": 0.0,
		"clump": 0.7, "gloss": 0.45},
	"ficus": {"leaf": "elliptic", "leaf_cm": 12.0, "spray_m": 0.9, "aspect": 0.7,
		"fill": 1.3, "shell": 10.0, "face_up": 0.55, "droop": 0.12, "upturn": 0.05,
		"clump": 0.4, "gloss": 0.6},
	# Olive: narrow grey-green leaves, silver below, a soft shimmering crown.
	"olive": {"leaf": "narrow", "leaf_cm": 6.0, "spray_m": 0.6, "aspect": 0.55,
		"fill": 1.0, "shell": 7.0, "face_up": 0.45, "droop": 0.25, "upturn": 0.15,
		"clump": 0.35, "under": 0.5},
	# Acacia: feathery bipinnate leaves on a flat-topped umbrella.
	"acacia": {"leaf": "fine", "leaf_cm": 12.0, "spray_m": 0.9, "aspect": 0.7,
		"fill": 0.9, "shell": 5.0, "face_up": 0.9, "droop": 0.0, "upturn": 0.0,
		"clump": 0.5, "leaflets": 14},
	"banana": {"leaf": "lance", "leaf_cm": 60.0, "spray_m": 1.6, "aspect": 0.55,
		"fill": 0.9, "shell": 4.0, "face_up": 0.4, "droop": 0.4, "upturn": 0.0,
		"clump": 0.9, "gloss": 0.3},
}


static func form_for(species: String) -> Dictionary:
	var base: Dictionary = FORMS["deciduous"]
	if not FORMS.has(species) or species == "deciduous":
		return base
	var out := base.duplicate()
	out.merge(FORMS[species] as Dictionary, true)
	return out


## The leaf sprays for one tree. `nodes` is the skeleton export
## (VegetationCardFactory._build_branch_skeleton's out_nodes); density_mul
## scales the leaf area (the quality tier's shell count and the foliage
## macro). Returns [verts, uvs, normals, colors, indices].
static func build_sprays(nodes: Dictionary, form: Dictionary, crown_w: float,
		density_mul: float, seed: int) -> Array:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var pos: PackedVector3Array = nodes.get("pos", PackedVector3Array())
	var parent: PackedInt32Array = nodes.get("parent", PackedInt32Array())
	var tipw: PackedFloat32Array = nodes.get("tipw", PackedFloat32Array())
	var y0 := float(nodes.get("y0", 0.0))
	var y1 := float(nodes.get("y1", 1.0))
	var env_r := maxf(float(nodes.get("env_r", crown_w * 0.5)), 0.5)
	var total_h := maxf(y1, 0.5)
	if pos.size() < 2:
		return [verts, uvs, normals, colors, indices]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var mid_y := (y0 + y1) * 0.5
	var half_h := maxf((y1 - y0) * 0.5, 0.5)
	var spray_l := spray_length(form, crown_w)
	var spray_w := spray_l * float(form["aspect"])
	# Leaf area wanted: the crown's outer surface (a capped cylinder is close
	# enough), about three cards deep once the texture's holes are counted —
	# at 1.8 the crown read as bare wire with leaves stuck on.
	var shell_area := TAU * env_r * env_r + TAU * env_r * (y1 - y0)
	var want := int(shell_area * 3.0 * float(form["fill"]) * density_mul
		/ maxf(spray_l * spray_w, 0.05))
	want = clampi(want, MIN_SPRAYS, MAX_SPRAYS)
	var shell := maxf(float(form["shell"]), 1.0)
	var clump := clampf(float(form["clump"]), 0.0, 0.95)
	# Weighted outer-twig length: leaves along twigs, thinning toward the
	# scaffold limbs (pipe-model tip count = how many twigs a branch feeds).
	var seg_w := PackedFloat32Array()
	seg_w.resize(pos.size())
	var total := 0.0
	var tip_count := 0
	for i in pos.size():
		var p := parent[i]
		if p < 0:
			continue
		var tw := tipw[i]
		var w := 0.0
		if tw <= 2.0:
			w = 1.0
		elif tw <= shell * 0.5:
			w = 0.8
		elif tw <= shell:
			w = 0.5
		elif tw <= shell * 2.0:
			w = 0.18
		seg_w[i] = w
		total += pos[i].distance_to(pos[p]) * w
		if tw <= 1.0:
			tip_count += 1
	if total <= 0.001:
		return [verts, uvs, normals, colors, indices]
	var at_tips := int(round(float(want) * clump))
	var along := maxi(want - at_tips, 0)
	var spacing := total / maxf(float(along), 1.0)
	var acc := rng.randf() * spacing
	# Scalars only: packed arrays fetched out of a Dictionary are COPIES, so
	# the arrays travel as arguments.
	# y_floor: no leaf below the authored crown base (less a hand's breadth)
	# — "crown base %" promises a clear trunk under the crown.
	var geo := {"mid_y": mid_y, "half_h": half_h, "env_r": env_r,
		"total_h": total_h, "y_floor": maxf(y0 - 0.4, 0.3)}
	for i in pos.size():
		var p := parent[i]
		if p < 0 or seg_w[i] <= 0.0:
			continue
		var a := pos[p]
		var b := pos[i]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.01:
			continue
		var dir := seg / seg_len
		acc += seg_len * seg_w[i]
		while acc >= spacing:
			acc -= spacing
			var f := clampf(1.0 - acc / maxf(seg_len * seg_w[i], 0.001), 0.0, 1.0)
			# The skeleton's twigs are a few metres apart: a real crown has
			# shoots all through that space, so each card sits a little off
			# its twig (more outward), filling the volume between them.
			var at := a.lerp(b, f)
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.7, 0.7),
				rng.randf_range(-1, 1)) * spray_l * 0.55
			var rad := Vector3(at.x, 0.0, at.z)
			if rad.length_squared() > 0.01:
				off += rad.normalized() * spray_l * rng.randf_range(0.0, 0.35)
			_place_spray(verts, uvs, normals, colors, indices, geo, at + off, dir,
				spray_l, spray_w, form, rng)
	# Clumps on the twig ends: each tip carries a fan.
	if tip_count > 0 and at_tips > 0:
		var per_tip := float(at_tips) / float(tip_count)
		var carry := rng.randf()
		for i in pos.size():
			var p := parent[i]
			if p < 0 or tipw[i] > 1.0:
				continue
			carry += per_tip
			var k := int(floor(carry))
			carry -= float(k)
			var dir := (pos[i] - pos[p]).normalized()
			for _j in k:
				var jitter := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.6),
					rng.randf_range(-1, 1)) * spray_l * 0.18
				_place_spray(verts, uvs, normals, colors, indices, geo, pos[i] + jitter,
					dir, spray_l, spray_w, form, rng)
	return [verts, uvs, normals, colors, indices]


## Card length for a form on a crown `crown_w` wide (the leaf texture is
## drawn to the same scale).
static func spray_length(form: Dictionary, crown_w: float) -> float:
	return float(form["spray_m"]) * SPRAY_SCALE * clampf(crown_w / 12.0, 0.55, 1.35)


## One spray: a quad from `at`, leaning out from the crown axis,
## fanned off the twig, its face turned toward the sky by face_up.
static func _place_spray(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, colors: PackedColorArray, idx: PackedInt32Array,
		geo: Dictionary, at: Vector3, twig: Vector3, spray_l: float,
		spray_w: float, form: Dictionary, rng: RandomNumberGenerator) -> void:
	var outward := Vector3(at.x, 0.0, at.z)
	if outward.length_squared() < 0.01:
		var az := rng.randf() * TAU
		outward = Vector3(cos(az), 0.0, sin(az))
	outward = outward.normalized()
	var rnd := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1),
		rng.randf_range(-1, 1)).normalized()
	var droop := float(form["droop"])
	var upturn := float(form["upturn"])
	var d := (twig * 0.45 + outward * 0.55 + rnd * 0.6
		+ Vector3.UP * (upturn * 0.6 - droop * 0.9)).normalized()
	var face_up := clampf(float(form["face_up"]), 0.0, 1.0)
	var n_t := (Vector3.UP * (0.25 + face_up) + outward * (1.0 - face_up) * 0.9
		+ Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3),
			rng.randf_range(-1, 1)) * 0.45).normalized()
	var side := d.cross(n_t)
	if side.length_squared() < 1e-5:
		side = d.cross(Vector3.RIGHT)
	side = side.normalized()
	var nrm := side.cross(d).normalized()
	if nrm.dot(n_t) < 0.0:
		nrm = -nrm
	var l := spray_l * rng.randf_range(0.78, 1.18)
	var w := spray_w * rng.randf_range(0.85, 1.12)
	# Leaves weigh the spray down toward its tip (more on hanging species).
	var sag := Vector3.DOWN * l * (0.06 + droop * 0.28)
	# One quad (2 triangles): at crown density the bend of a two-quad strip
	# never read, and it doubled the leaf triangles.
	var pts: Array[Vector3] = [at, at + d * l + sag]
	var widths: Array[float] = [w * 0.8, w]
	var base := verts.size()
	var mid_y := float(geo["mid_y"])
	var half_h := float(geo["half_h"])
	var env_r := float(geo["env_r"])
	var total_h := float(geo["total_h"])
	var floor_y := float(geo["y_floor"])
	var rid := rng.randf()
	for k in 2:
		var c: Vector3 = pts[k]
		c.y = maxf(c.y, floor_y)
		var u := float(k)
		for e in 2:
			var q := c + side * widths[k] * (0.5 if e == 0 else -0.5)
			q.y = maxf(q.y, floor_y)
			verts.append(q)
			uvs.append(Vector2(u, float(e)))
			# Lit as part of the crown volume, not as a lone card: bend the
			# leaf normal toward the crown's own outward normal.
			var cn := Vector3(q.x / env_r, (q.y - mid_y) / half_h, q.z / env_r)
			var crown_n := cn.normalized() if cn.length_squared() > 1e-4 else Vector3.UP
			normals.append((nrm * 0.6 + crown_n * 0.4 + Vector3.UP * 0.15).normalized())
			var depth := clampf(1.0 - cn.length(), 0.0, 1.0)
			colors.append(Color(depth, clampf(q.y / total_h, 0.0, 1.0), rid, 1.0))
	idx.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])


# --- the leaf spray texture --------------------------------------------------

## One twig with the species' leaves, U along the twig (0 at its base),
## V across, the twig on the centre line. Leaves are drawn to scale against
## the spray length, on side twiglets when they are small.
static func leaf_texture(spec: Dictionary, form: Dictionary, seed: int) -> ImageTexture:
	var img := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var top: Color = spec.get("top", Color(0.18, 0.38, 0.10))
	var bottom: Color = spec.get("bottom", Color(0.24, 0.16, 0.06))
	var hi: Color = spec.get("highlight", Color(0.42, 0.52, 0.16))
	var twig_col := Color(0.24, 0.17, 0.11)
	var style := str(form["leaf"])
	var spray_l := float(form["spray_m"]) * SPRAY_SCALE
	# Pixels per metre along the twig, and the leaf length in pixels.
	var ppm := float(TEX_W) * 0.94 / spray_l
	var leaf_px := clampf(float(form["leaf_cm"]) / 100.0 * ppm, 10.0, float(TEX_H) * 0.62)
	var cy := float(TEX_H) * 0.5
	var stem_end := Vector2(float(TEX_W) * 0.86, cy + rng.randf_range(-6, 6))
	var twigs: Array = [[Vector2(2, cy), stem_end]]
	# Small leaves need more twig to hang on: side twiglets.
	var side_twigs := clampi(int(round(float(TEX_H) * 0.62 / leaf_px)), 1, 5)
	for i in side_twigs * 2:
		var f := lerpf(0.18, 0.78, (float(i >> 1) + 0.5) / float(maxi(side_twigs, 1)))
		var sgn := 1.0 if i % 2 == 0 else -1.0
		var s0 := Vector2(2, cy).lerp(stem_end, f)
		var ang := deg_to_rad(rng.randf_range(32.0, 52.0)) * sgn
		var ln := float(TEX_W) * rng.randf_range(0.22, 0.34) * (1.0 - f * 0.4)
		var e := s0 + Vector2(cos(ang), sin(ang)) * ln
		e.y = clampf(e.y, leaf_px * 0.35, float(TEX_H) - leaf_px * 0.35)
		twigs.append([s0, e])
	# Leaves along every twig, alternate sides, and one at each twig end.
	var leaves: Array = []
	for t in twigs:
		var a: Vector2 = t[0]
		var b: Vector2 = t[1]
		var tl := a.distance_to(b)
		var tdir := (b - a) / maxf(tl, 0.001)
		var step := leaf_px * (0.30 if style != "pinnate" else 0.6)
		var n := maxi(int(tl / step), 1)
		for j in n:
			var f := (float(j) + 0.6) / float(n)
			if f < 0.12:
				continue
			var p := a.lerp(b, f)
			var sgn := 1.0 if j % 2 == 0 else -1.0
			var ang := atan2(tdir.y, tdir.x) + sgn * deg_to_rad(rng.randf_range(38.0, 70.0))
			leaves.append([p, ang, leaf_px * rng.randf_range(0.78, 1.08)])
		leaves.append([b, atan2(tdir.y, tdir.x) + rng.randf_range(-0.25, 0.25), leaf_px])
	for t in twigs:
		_stroke(img, t[0], t[1], 2.2 if t == twigs[0] else 1.5, twig_col)
	for lf in leaves:
		var col := bottom.lerp(top, rng.randf_range(0.55, 1.05))
		if rng.randf() < 0.15:
			col = col.lerp(hi, 0.45)
		_leaf(img, lf[0], float(lf[1]), float(lf[2]), style, col, form, rng)
	return ImageTexture.create_from_image(finalize_cutout(img, ALPHA_CUT))


## Mip chain for an alpha-CUTOUT texture (leaves, needles):
##   * transparent texels take the leaves' mean colour first — Godot's
##     mipmaps average RGB with the black of empty texels, which darkened
##     every leaf edge and turned whole crowns near-black at a distance;
##   * each mip's alpha is then scaled so the share of texels above `cut`
##     matches the full-size image (Castano 2010, "coverage-preserving
##     mipmaps") — averaged alpha of small leaves sinks below the cut and a
##     crown thinned to bare twigs as it moved away.
static func finalize_cutout(img: Image, cut: float) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var sum := Color(0, 0, 0, 0)
	var n := 0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				sum += Color(c.r, c.g, c.b, 0.0)
				n += 1
	var mean := Color(0.2, 0.3, 0.1) if n == 0 else Color(sum.r / n, sum.g / n, sum.b / n)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a < 0.02:
				img.set_pixel(x, y, Color(mean.r, mean.g, mean.b, 0.0))
	img.generate_mipmaps()
	var data := img.get_data()
	var cut_b := int(cut * 255.0)
	var cov0 := _coverage(data, 0, w * h, cut_b, 1.0)
	var levels := img.get_mipmap_count()
	var lw := w
	var lh := h
	for level in range(1, levels + 1):
		lw = maxi(lw >> 1, 1)
		lh = maxi(lh >> 1, 1)
		var off := img.get_mipmap_offset(level)
		var count := lw * lh
		var lo := 1.0
		var hi := 6.0
		for _it in 12:
			var mid := (lo + hi) * 0.5
			if _coverage(data, off, count, cut_b, mid) < cov0:
				lo = mid
			else:
				hi = mid
		var s := (lo + hi) * 0.5
		for i in count:
			var ai := off + i * 4 + 3
			data[ai] = mini(int(float(data[ai]) * s), 255)
	return Image.create_from_data(w, h, true, Image.FORMAT_RGBA8, data)


static func _coverage(data: PackedByteArray, off: int, count: int, cut_b: int,
		scale: float) -> float:
	var above := 0
	for i in count:
		if float(data[off + i * 4 + 3]) * scale > float(cut_b):
			above += 1
	return float(above) / float(maxi(count, 1))


## Half the leaf's width at u (0 = stalk end, 1 = tip) as a fraction of its
## length, for each outline.
static func _half_width(style: String, u: float, teeth: float) -> float:
	var w := 0.0
	match style:
		"elliptic":
			w = 0.30 * pow(sin(PI * u), 0.85)
		"serrate":
			w = 0.33 * pow(sin(PI * pow(u, 0.9)), 0.8)
		"lance", "lance_serrate":
			w = 0.17 * pow(sin(PI * pow(u, 0.75)), 0.8)
		"narrow":
			w = 0.085 * sin(PI * u)
		"deltoid":
			w = 0.44 * pow(maxf(1.0 - u, 0.0), 0.85) * smoothstep(0.0, 0.14, u)
		"triangular":
			w = 0.36 * pow(maxf(1.0 - u, 0.0), 0.9) * smoothstep(0.0, 0.2, u)
		"round":
			w = 0.47 * sqrt(maxf(1.0 - pow(2.0 * u - 1.0, 2.0), 0.0)) * (1.0 - 0.25 * u * u * u)
		"lobed":
			# Three to four rounded lobes a side, cut deep (Garry oak).
			w = 0.34 * pow(sin(PI * u), 0.8) \
				* (0.32 + 0.68 * smoothstep(0.0, 1.0, absf(sin(u * PI * 3.5))))
		_:
			w = 0.32 * pow(sin(PI * pow(u, 0.85)), 0.85)
	if teeth > 0.0 and w > 0.0:
		var saw := absf(fposmod(u * teeth, 1.0) - 0.5) * 2.0
		w *= 1.0 - 0.10 * saw
	return w


static func _leaf(img: Image, base: Vector2, ang: float, length: float, style: String,
		col: Color, form: Dictionary, rng: RandomNumberGenerator) -> void:
	if style == "pinnate" or style == "fine":
		_compound_leaf(img, base, ang, length, style, col, form, rng)
		return
	var axis := Vector2(cos(ang), sin(ang))
	var perp := Vector2(-axis.y, axis.x)
	var stalk := length * (0.18 if style == "palmate" or style == "round" else 0.08)
	var b := base + axis * stalk
	_stroke(img, base, b, 1.2, col.darkened(0.35))
	var teeth := 0.0
	match style:
		"serrate", "triangular", "lance_serrate":
			teeth = 22.0
		"round":
			teeth = 14.0
	var gloss := float(form.get("gloss", 0.0))
	var reach := length * (1.0 if style != "palmate" else 1.05)
	var lo := b - Vector2(reach, reach)
	var hi_p := b + Vector2(reach, reach)
	var minx := clampi(int(lo.x), 0, TEX_W - 1)
	var maxx := clampi(int(hi_p.x), 0, TEX_W - 1)
	var miny := clampi(int(lo.y), 0, TEX_H - 1)
	var maxy := clampi(int(hi_p.y), 0, TEX_H - 1)
	var shade := rng.randf_range(-0.05, 0.05)
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5) - b
			var cov := 0.0
			var vein := 1.0
			var u := 0.0
			if style == "palmate":
				# Five pointed lobes round the stalk end (maple): the radius
				# swings between lobe tips and the sinuses between them.
				var c := axis * length * 0.42
				var q := p - c
				var r := q.length()
				var th := atan2(q.dot(perp), q.dot(axis))
				# Pointed lobes (a high power of |cos|), deep sinuses between —
				# a soft power drew round clover leaves.
				var lobe := pow(absf(cos(th * 2.5)), 1.15)
				var rmax := length * 0.54 * (0.44 + 0.56 * lobe)
				# The stalk sinus: nothing straight back toward the stalk.
				if absf(th) > 2.6:
					rmax *= 0.55
				cov = clampf(rmax - r + 0.5, 0.0, 1.0)
				u = clampf(r / maxf(rmax, 0.01), 0.0, 1.0)
				# Five main veins from the base.
				var vk := absf(fposmod(th / (TAU / 5.0) + 0.5, 1.0) - 0.5)
				vein = 0.82 + 0.18 * smoothstep(0.0, 0.06, vk)
			else:
				var along := p.dot(axis) / length
				var across := absf(p.dot(perp)) / length
				if along < 0.0 or along > 1.0:
					continue
				var hw := _half_width(style, along, teeth)
				cov = clampf((hw - across) * length + 0.5, 0.0, 1.0)
				u = along
				vein = 0.80 + 0.20 * smoothstep(0.0, 0.018, across)
			if cov <= 0.0:
				continue
			var cc := col.lightened(0.10 * u) if u > 0.5 else col
			cc = cc.darkened(1.0 - vein)
			if gloss > 0.0:
				cc = cc.lerp(Color(0.85, 0.92, 0.80), gloss * 0.25 * (1.0 - u))
			cc = cc.lightened(shade) if shade > 0.0 else cc.darkened(-shade)
			_blend(img, x, y, cc, cov)


## Pinnate / bipinnate: a rachis with paired leaflets (walnut, acacia).
static func _compound_leaf(img: Image, base: Vector2, ang: float, length: float,
		style: String, col: Color, form: Dictionary, rng: RandomNumberGenerator) -> void:
	var axis := Vector2(cos(ang), sin(ang))
	var tip := base + axis * length
	_stroke(img, base, tip, 1.2, col.darkened(0.3))
	var n := maxi(int(form.get("leaflets", 9)), 3)
	var lf := length * (0.30 if style == "pinnate" else 0.16)
	for i in n:
		var f := lerpf(0.18, 1.0, float(i) / float(n - 1))
		var p := base.lerp(tip, f)
		for sgn in [-1.0, 1.0]:
			if f >= 0.99 and sgn > 0.0:
				continue
			var a2: float = ang + float(sgn) * deg_to_rad(55.0) if f < 0.99 else ang
			var shape := "elliptic"
			_leaf(img, p, a2, lf * (1.0 - 0.3 * absf(f - 0.55)), shape,
				col.lerp(col.lightened(0.1), rng.randf()), {"gloss": 0.0}, rng)


static func _blend(img: Image, x: int, y: int, c: Color, cov: float) -> void:
	var cur := img.get_pixel(x, y)
	if cur.a <= 0.0:
		img.set_pixel(x, y, Color(c.r, c.g, c.b, cov))
		return
	img.set_pixel(x, y, Color(lerpf(cur.r, c.r, cov), lerpf(cur.g, c.g, cov),
		lerpf(cur.b, c.b, cov), maxf(cur.a, cov)))


static func _stroke(img: Image, a: Vector2, b: Vector2, width: float, col: Color) -> void:
	var minx := clampi(int(minf(a.x, b.x) - width - 1.0), 0, TEX_W - 1)
	var maxx := clampi(int(maxf(a.x, b.x) + width + 1.0), 0, TEX_W - 1)
	var miny := clampi(int(minf(a.y, b.y) - width - 1.0), 0, TEX_H - 1)
	var maxy := clampi(int(maxf(a.y, b.y) + width + 1.0), 0, TEX_H - 1)
	var ab := b - a
	var l2 := maxf(ab.length_squared(), 0.0001)
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			var cov := clampf(width * 0.5 + 0.5 - d, 0.0, 1.0)
			if cov > 0.0:
				_blend(img, x, y, col, cov)

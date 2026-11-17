class_name GardenCrops
extends RefCounted

## Procedural garden crops for grow beds: one low-poly mesh per crop at its
## MATURE size, in metres, base at the origin, +Y up. GrowBed scatters them on
## each bed at the crop's real spacing (biointensive offset rows) as one
## MultiMesh per crop, and garden_crop.gdshader grows every plant from its
## sowing day on the bed's clock (INSTANCE_CUSTOM = sow day, cycle, maturity,
## seed), so a bed is planted in succession and nothing is updated per plant.
##
## Vertex data the shader reads:
##   COLOR  the part's own colour (fruit: its ripe colour)
##   UV.x   part: 0 foliage / stems, 1 fruit or flower, 2 structure (stakes,
##          poles, a coppice stool) that does not grow
##   UV.y   height fraction (0 at the soil, 1 at the top) for sway + shading
##   UV2.x  fruit / flower: the share of the cycle from which it shows
##
## Spacings are the usual intensive-bed ones (Jeavons, How to Grow More
## Vegetables, 9th ed., Master Charts; offset/hexagonal rows): lettuce 25 cm,
## chard 30, kale 45, tomato 50, pepper 40, squash 90, pole beans one teepee
## of six plants per 90 cm, carrots and onions in clumps per 20 cm cell,
## potato 40, sweet potato 50, basil 25. Willow coppice is planted in twin
## rows 0.75 m apart with 1.5 m between pairs, 0.6 m in the row (about
## 15 000 stools a hectare; UK Biomass Energy Centre guidance), cut every
## third year; sorghum-sudan grass in 50 cm clumps, cut every 100 days.
## Cycle days are sowing to the last harvest of a planting; the bed is cleared
## and sown again. All of it is look only: what the bed yields is the plant
## node's own model (PlantGrowth).

const PART_LEAF := 0.0
const PART_FRUIT := 1.0
const PART_STRUCT := 2.0

## id -> {spacing (m), cycle (days), mature (share of the cycle at full
## size), height (m), shadow (casts shadows), label}
const CROPS := {
	"lettuce": {"spacing": 0.25, "cycle": 55.0, "mature": 0.85, "height": 0.2, "label": "Lettuce"},
	"lettuce_red": {"spacing": 0.25, "cycle": 55.0, "mature": 0.85, "height": 0.2, "label": "Red lettuce"},
	"romaine": {"spacing": 0.25, "cycle": 65.0, "mature": 0.85, "height": 0.32, "label": "Romaine"},
	"kale": {"spacing": 0.45, "cycle": 150.0, "mature": 0.4, "height": 0.62, "label": "Kale"},
	"chard": {"spacing": 0.3, "cycle": 120.0, "mature": 0.4, "height": 0.48, "label": "Chard"},
	"tomato": {"spacing": 0.5, "cycle": 150.0, "mature": 0.45, "height": 1.7, "shadow": true, "label": "Tomato"},
	"pepper_red": {"spacing": 0.4, "cycle": 150.0, "mature": 0.5, "height": 0.6, "label": "Pepper"},
	"pepper_yellow": {"spacing": 0.4, "cycle": 150.0, "mature": 0.5, "height": 0.6, "label": "Pepper"},
	"zucchini": {"spacing": 0.9, "cycle": 100.0, "mature": 0.45, "height": 0.6, "label": "Zucchini"},
	"squash": {"spacing": 0.9, "cycle": 120.0, "mature": 0.5, "height": 0.55, "label": "Winter squash"},
	"beans": {"spacing": 0.9, "cycle": 90.0, "mature": 0.55, "height": 1.95, "shadow": true, "label": "Pole beans"},
	"carrot": {"spacing": 0.2, "cycle": 80.0, "mature": 0.8, "height": 0.32, "label": "Carrots"},
	"onion": {"spacing": 0.2, "cycle": 120.0, "mature": 0.75, "height": 0.42, "label": "Onions"},
	"potato": {"spacing": 0.4, "cycle": 110.0, "mature": 0.6, "height": 0.55, "label": "Potato"},
	"sweet_potato": {"spacing": 0.5, "cycle": 140.0, "mature": 0.5, "height": 0.3, "label": "Sweet potato"},
	"basil": {"spacing": 0.25, "cycle": 90.0, "mature": 0.6, "height": 0.35, "label": "Basil"},
	"willow": {"spacing": 0.6, "cycle": 1095.0, "mature": 0.7, "height": 3.4, "shadow": true, "label": "Willow coppice"},
	"sorghum": {"spacing": 0.5, "cycle": 100.0, "mature": 0.7, "height": 2.3, "shadow": true, "label": "Sorghum-sudan grass"},
	# Terrace crops (TerraceField). Rice is transplanted in hills of 3-4
	# seedlings 20-25 cm apart; one mesh here is a hill. Common reed
	# (Phragmites australis) stands 2-3 m in a bed cut once a year; taro
	# (Colocasia esculenta) on wet terraces at ~60 cm.
	"rice": {"spacing": 0.25, "cycle": 120.0, "mature": 0.7, "height": 0.95, "label": "Rice"},
	"reed": {"spacing": 0.35, "cycle": 365.0, "mature": 0.55, "height": 2.5, "shadow": true, "label": "Reed"},
	"taro": {"spacing": 0.6, "cycle": 270.0, "mature": 0.5, "height": 1.1, "label": "Taro"},
}

## Crop plans by ring (outer first) for a mixed kitchen garden: tall and
## sprawling crops on the outside, the calorie crops (potato, sweet potato,
## beans, squash) about half of it, salads and roots within reach of the
## middle.
## A run of raised beds, section by section.
const GARDEN_BEDS := ["lettuce", "carrot", "kale", "onion", "chard", "basil", "tomato", "beans",
	"pepper_red", "lettuce_red", "potato", "squash", "romaine", "sweet_potato"]

const GARDEN_RINGS := [
	["tomato", "beans", "squash", "tomato", "beans", "zucchini", "sweet_potato", "potato"],
	["potato", "pepper_red", "kale", "potato", "sweet_potato", "pepper_yellow", "chard", "beans"],
	["lettuce", "carrot", "onion", "chard", "romaine", "basil", "lettuce_red", "carrot"],
	["lettuce", "basil", "onion", "lettuce_red"],
	["lettuce", "basil"],
]

static var _cache: Dictionary = {}


static func info(id: String) -> Dictionary:
	return CROPS.get(id, CROPS["lettuce"]) as Dictionary


static func spacing(id: String) -> float:
	return float(info(id)["spacing"])


## The mature mesh of a crop (cached).
static func mesh(id: String) -> ArrayMesh:
	if _cache.has(id):
		return _cache[id]
	var k := Kit.new()
	k.height = float(info(id)["height"])
	k.rng.seed = hash(id)
	match id:
		"lettuce": _lettuce(k, Color(0.46, 0.74, 0.26), Color(0.66, 0.86, 0.38), false)
		"lettuce_red": _lettuce(k, Color(0.48, 0.2, 0.18), Color(0.55, 0.72, 0.3), false)
		"romaine": _lettuce(k, Color(0.3, 0.58, 0.2), Color(0.6, 0.8, 0.36), true)
		"kale": _kale(k)
		"chard": _chard(k)
		"tomato": _tomato(k)
		"pepper_red": _pepper(k, Color(0.82, 0.1, 0.07))
		"pepper_yellow": _pepper(k, Color(0.96, 0.76, 0.1))
		"zucchini": _squash(k, false)
		"squash": _squash(k, true)
		"beans": _beans(k)
		"carrot": _carrots(k)
		"onion": _onions(k)
		"potato": _potato(k)
		"sweet_potato": _sweet_potato(k)
		"basil": _basil(k)
		"willow": _willow(k)
		"sorghum": _sorghum(k)
		"rice": _rice(k)
		"reed": _reed(k)
		"taro": _taro(k)
		_: _lettuce(k, Color(0.46, 0.74, 0.26), Color(0.66, 0.86, 0.38), false)
	var m := k.commit()
	_cache[id] = m
	return m


## Triangles in a crop's mesh (for the bench / selftest).
static func triangle_count(id: String) -> int:
	var m := mesh(id)
	if m.get_surface_count() == 0:
		return 0
	return int((m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3)


# ---------------------------------------------------------------------------
# The crops
# ---------------------------------------------------------------------------

static func _lettuce(k: Kit, outer: Color, inner: Color, upright: bool) -> void:
	var n := 14
	for i in n:
		var t := float(i) / float(n - 1)          # 0 = outer leaf, 1 = heart
		var yaw := float(i) * 2.39996
		var pitch := deg_to_rad(lerpf(22.0, 70.0, t) + (16.0 if upright else 0.0))
		var ln := lerpf(0.17, 0.08, t) * (1.5 if upright else 1.0)
		var col := outer.lerp(inner, t)
		k.leaf(Vector3(0.0, 0.01 + 0.02 * t, 0.0), _dir(yaw), pitch, ln, ln * (0.5 if upright else 0.85),
			0.35 if upright else 0.8, col, "oval", 0.38, 3)

static func _kale(k: Kit) -> void:
	k.stem(Vector3.ZERO, Vector3(0.0, 0.26, 0.0), 0.02, 0.016, Color(0.42, 0.5, 0.4))
	for i in 12:
		var t := float(i) / 11.0
		var y := lerpf(0.08, 0.28, t)
		var yaw := float(i) * 2.39996
		k.leaf(Vector3(0.0, y, 0.0), _dir(yaw), deg_to_rad(lerpf(38.0, 70.0, t)), lerpf(0.42, 0.28, t),
			lerpf(0.2, 0.15, t), 1.1, Color(0.2, 0.34, 0.3).lerp(Color(0.3, 0.44, 0.38), t), "wavy", 0.32, 5)

static func _chard(k: Kit) -> void:
	var stems := [Color(0.78, 0.12, 0.16), Color(0.92, 0.76, 0.18), Color(0.92, 0.9, 0.82),
		Color(0.9, 0.4, 0.12)]
	for i in 8:
		var yaw := float(i) * 2.39996
		var d := _dir(yaw)
		var pitch := deg_to_rad(lerpf(52.0, 75.0, float(i) / 7.0))
		var top := Vector3(0.0, 0.0, 0.0) + d * cos(pitch) * 0.16 + Vector3.UP * sin(pitch) * 0.2
		k.stem(Vector3(0.0, 0.0, 0.0), top, 0.008, 0.006, stems[i % stems.size()])
		k.leaf(top, d, pitch - 0.25, 0.26, 0.15, 0.6, Color(0.17, 0.38, 0.14), "oval", 0.22, 4)


static func _tomato(k: Kit) -> void:
	k.part = PART_STRUCT
	k.box(Vector3(0.05, 0.0, 0.0), Vector3(0.05, 1.7, 0.0), 0.022, Color(0.55, 0.42, 0.27))
	k.part = PART_LEAF
	var prev := Vector3.ZERO
	var nodes := 7
	for i in nodes:
		var t := float(i + 1) / float(nodes)
		var p := Vector3(sin(float(i) * 1.7) * 0.04, 1.5 * t, cos(float(i) * 1.3) * 0.04)
		k.stem(prev, p, 0.014 * (1.0 - t * 0.5), 0.012 * (1.0 - t * 0.5), Color(0.3, 0.48, 0.2))
		prev = p
		var yaw := float(i) * 2.2
		var sz := 1.15 - t * 0.35
		_compound_leaf(k, p, _dir(yaw), deg_to_rad(18.0), 0.34 * sz, 0.11 * sz, Color(0.2, 0.42, 0.16), 5)
		_compound_leaf(k, p - Vector3(0, 0.06, 0), _dir(yaw + PI * 0.85), deg_to_rad(10.0), 0.3 * sz, 0.1 * sz,
			Color(0.24, 0.46, 0.18), 5)
		if i >= 1 and i <= 5:
			# A truss of fruit hangs off the stem below the leaf.
			k.part = PART_FRUIT
			k.fruit_from = 0.38 + 0.03 * float(i)
			var c := p + _dir(yaw + 1.6) * 0.08 - Vector3(0.0, 0.1, 0.0)
			for j in 3:
				var o := Vector3(k.jitter(0.035), -float(j) * 0.04, k.jitter(0.035))
				var r := 0.03 + k.rng.randf() * 0.012
				k.blob(c + o, Vector3(r, r * 0.88, r), Color(0.86, 0.13, 0.07), 2)
			k.part = PART_LEAF
			k.fruit_from = 0.0

static func _compound_leaf(k: Kit, base: Vector3, d: Vector3, pitch: float, ln: float, lf: float,
		col: Color, leaflets: int) -> void:
	var tip := base + d * cos(pitch) * ln + Vector3.UP * (sin(pitch) * ln - ln * 0.25)
	k.stem(base, tip, 0.004, 0.003, col.darkened(0.15))
	var side := Vector3.UP.cross(d).normalized()
	for i in leaflets:
		var t := (float(i) + 0.6) / float(leaflets)
		var p := base.lerp(tip, t)
		var sgn := 1.0 if i % 2 == 0 else -1.0
		k.leaf(p, (side * sgn + d * 0.35).normalized(), deg_to_rad(-2.0), lf, lf * 0.6, 0.6, col, "oval", 0.0, 2)
	k.leaf(tip, d, deg_to_rad(-15.0), lf * 1.1, lf * 0.6, 0.5, col, "oval", 0.0, 2)

static func _pepper(k: Kit, fruit: Color) -> void:
	var tips: Array = []
	var col := Color(0.28, 0.45, 0.2)
	for b in 3:
		var d := _dir(float(b) * 2.1)
		var fork := d * 0.03 + Vector3(0.0, 0.12, 0.0)
		k.stem(Vector3.ZERO, fork, 0.013, 0.01, col)
		tips.append(fork)
		for f in 2:
			var d2 := d.rotated(Vector3.UP, (float(f) - 0.5) * 1.0)
			var top := fork + d2 * 0.14 + Vector3(0.0, 0.26 + 0.06 * float(f), 0.0)
			k.stem(fork, top, 0.009, 0.006, col)
			tips.append(fork.lerp(top, 0.45))
			tips.append(top)
	for i in 34:
		var p: Vector3 = tips[i % tips.size()] + Vector3(k.jitter(0.05), k.jitter(0.03), k.jitter(0.05))
		k.leaf(p, _dir(float(i) * 2.39996), deg_to_rad(18.0 + k.jitter(12.0)), 0.13, 0.065, 0.6,
			Color(0.16, 0.38, 0.12).lerp(Color(0.24, 0.46, 0.16), k.rng.randf()), "oval", 0.0, 3)
	k.part = PART_FRUIT
	for i in 6:
		k.fruit_from = 0.45 + 0.02 * float(i)
		var p2: Vector3 = tips[(i * 2 + 1) % tips.size()] + Vector3(k.jitter(0.05), -0.06, k.jitter(0.05))
		k.blob(p2, Vector3(0.032, 0.06, 0.032), fruit, 2)
	k.part = PART_LEAF
	k.fruit_from = 0.0

static func _squash(k: Kit, winter: bool) -> void:
	var leaf_col := Color(0.2, 0.42, 0.16)
	for i in 8:
		var yaw := float(i) * 2.39996
		var d := _dir(yaw)
		var pitch := deg_to_rad(lerpf(55.0, 30.0, float(i % 4) / 3.0))
		var ln := 0.3 + 0.15 * float(i % 3) / 2.0
		var top := d * cos(pitch) * ln + Vector3.UP * sin(pitch) * ln
		k.stem(Vector3(0.0, 0.03, 0.0), top, 0.012, 0.008, Color(0.36, 0.5, 0.26))
		k.leaf(top, d, deg_to_rad(-8.0), 0.3, 0.32, 0.3, leaf_col.lerp(Color(0.32, 0.52, 0.24), k.rng.randf() * 0.4),
			"palmate", 0.15, 4)
	k.part = PART_FRUIT
	k.fruit_from = 0.3
	for i in 3:
		var d2 := _dir(float(i) * 2.0 + 0.5)
		k.blob(d2 * 0.22 + Vector3(0.0, 0.15, 0.0), Vector3(0.04, 0.035, 0.04), Color(0.98, 0.78, 0.12), 0)
	if winter:
		k.fruit_from = 0.5
		k.blob(Vector3(0.35, 0.11, 0.1), Vector3(0.13, 0.11, 0.13), Color(0.92, 0.55, 0.12), 1)
		k.blob(Vector3(-0.2, 0.09, -0.32), Vector3(0.09, 0.09, 0.15), Color(0.86, 0.72, 0.46), 1)
	else:
		k.fruit_from = 0.42
		k.blob(Vector3(0.3, 0.05, 0.12), Vector3(0.045, 0.045, 0.16), Color(0.2, 0.36, 0.14), 1)
		k.blob(Vector3(-0.15, 0.05, -0.3), Vector3(0.045, 0.045, 0.15), Color(0.24, 0.4, 0.16), 1)
	k.part = PART_LEAF
	k.fruit_from = 0.0


static func _beans(k: Kit) -> void:
	var apex := Vector3(0.0, 1.95, 0.0)
	for p in 3:
		var d := _dir(float(p) * TAU / 3.0)
		var foot := d * 0.36
		k.part = PART_STRUCT
		k.box(foot, apex, 0.018, Color(0.5, 0.42, 0.3))
		k.part = PART_LEAF
		# A vine twines up each pole, clothed in trifoliate leaves, with pods.
		var prev := foot
		var nodes := 10
		for i in nodes:
			var t := float(i + 1) / float(nodes)
			var on := foot.lerp(apex, t * 0.92)
			var ang := t * TAU * 2.5 + float(p)
			var q := on + Vector3(cos(ang), 0.0, sin(ang)) * 0.03
			k.stem(prev, q, 0.004, 0.004, Color(0.32, 0.5, 0.22))
			prev = q
			var out := (Vector3(q.x, 0.0, q.z).normalized() + Vector3(cos(ang), 0.0, sin(ang)) * 0.6).normalized()
			var sz := 1.2 - t * 0.4
			for f in 3:
				var fd := out.rotated(Vector3.UP, (float(f) - 1.0) * 0.9)
				k.leaf(q, fd, deg_to_rad(-15.0 + 25.0 * float(f % 2)), 0.11 * sz, 0.1 * sz, 0.5,
					Color(0.22, 0.46, 0.16).lerp(Color(0.3, 0.52, 0.2), k.rng.randf()), "heart", 0.0, 2)
			if i >= 2 and i % 2 == 0:
				k.part = PART_FRUIT
				k.fruit_from = 0.45 + 0.02 * float(i)
				for pd in 2:
					var pod := q + out.rotated(Vector3.UP, float(pd) * 0.8) * 0.06
					k.blob(pod - Vector3(0.0, 0.07, 0.0), Vector3(0.008, 0.075, 0.01), Color(0.36, 0.62, 0.2), 0)
				k.part = PART_LEAF
				k.fruit_from = 0.0

static func _carrots(k: Kit) -> void:
	for pl in 4:
		var c := Vector3(k.jitter(0.07), 0.0, k.jitter(0.07))
		for f in 3:
			k.leaf(c, _dir(float(f) * 2.1 + float(pl)), deg_to_rad(68.0 + k.jitter(10.0)), 0.28, 0.07, 0.6,
				Color(0.28, 0.54, 0.17), "fern", 0.0, 4)
		k.part = PART_FRUIT
		k.fruit_from = 0.65
		k.blob(c + Vector3(0.0, 0.004, 0.0), Vector3(0.014, 0.01, 0.014), Color(0.92, 0.48, 0.12), 0)
		k.part = PART_LEAF
		k.fruit_from = 0.0


static func _onions(k: Kit) -> void:
	for pl in 4:
		var c := Vector3(k.jitter(0.07), 0.0, k.jitter(0.07))
		for f in 4:
			k.leaf(c + Vector3(0.0, 0.02, 0.0), _dir(float(f) * 1.57 + float(pl)), deg_to_rad(80.0 - float(f) * 4.0),
				0.38, 0.018, 0.5, Color(0.36, 0.56, 0.32), "strap", 0.0, 3)
		k.part = PART_FRUIT
		k.fruit_from = 0.55
		k.blob(c + Vector3(0.0, 0.025, 0.0), Vector3(0.035, 0.03, 0.035), Color(0.84, 0.66, 0.46), 0)
		k.part = PART_LEAF
		k.fruit_from = 0.0


static func _potato(k: Kit) -> void:
	var tops: Array = []
	for s in 7:
		var d := _dir(float(s) * 0.9 + k.jitter(0.3))
		var pitch := deg_to_rad(42.0 + k.jitter(10.0))
		var top := d * cos(pitch) * 0.3 + Vector3.UP * sin(pitch) * 0.36
		k.stem(Vector3.ZERO, top, 0.011, 0.007, Color(0.26, 0.42, 0.2))
		tops.append(top)
		for j in 2:
			var p := Vector3.ZERO.lerp(top, 0.5 + 0.45 * float(j))
			_compound_leaf(k, p, _dir(float(s) * 0.9 + float(j) * 2.0 + 0.5), deg_to_rad(20.0), 0.2, 0.1,
				Color(0.19, 0.37, 0.14).lerp(Color(0.26, 0.44, 0.18), k.rng.randf()), 3)
	k.part = PART_FRUIT
	for i in 3:
		k.fruit_from = 0.35
		var t: Vector3 = tops[i * 2]
		for f in 3:
			k.blob(t + Vector3(k.jitter(0.03), 0.04 + k.jitter(0.015), k.jitter(0.03)), Vector3(0.014, 0.011, 0.014),
				Color(0.93, 0.92, 0.95), 0)
	k.part = PART_LEAF
	k.fruit_from = 0.0

static func _sweet_potato(k: Kit) -> void:
	for v in 5:
		var d := _dir(float(v) * TAU / 5.0 + k.jitter(0.3))
		var prev := Vector3(0.0, 0.02, 0.0)
		for i in 6:
			var p := d * (0.09 + 0.09 * float(i + 1)) + Vector3(k.jitter(0.03), 0.02, k.jitter(0.03))
			k.stem(prev, p, 0.005, 0.005, Color(0.42, 0.34, 0.22))
			prev = p
			var col := Color(0.24, 0.5, 0.2) if (i + v) % 3 != 0 else Color(0.36, 0.3, 0.28)
			for f in 2:
				var lp := p + Vector3(k.jitter(0.03), 0.06 + 0.06 * float(f) + k.jitter(0.03), k.jitter(0.03))
				k.leaf(lp, _dir(k.rng.randf() * TAU), deg_to_rad(18.0), 0.12, 0.11, 0.4, col, "heart", 0.0, 2)

static func _basil(k: Kit) -> void:
	for s in 3:
		var d := _dir(float(s) * 2.09 + 0.4)
		var top := d * 0.08 + Vector3(0.0, 0.3, 0.0)
		k.stem(Vector3.ZERO, top, 0.006, 0.004, Color(0.3, 0.5, 0.22))
		for j in 3:
			var p := Vector3.ZERO.lerp(top, 0.35 + 0.3 * float(j))
			for o in 2:
				k.leaf(p, _dir(float(s) * 1.57 + float(j) * 0.8 + float(o) * PI), deg_to_rad(25.0), 0.06, 0.04, 0.5,
					Color(0.32, 0.64, 0.22), "oval", 0.45, 2)


static func _willow(k: Kit) -> void:
	k.part = PART_STRUCT
	k.blob(Vector3(0.0, 0.08, 0.0), Vector3(0.12, 0.1, 0.12), Color(0.36, 0.29, 0.22), 1)
	k.part = PART_LEAF
	for s in 7:
		var d := _dir(float(s) * 2.39996)
		var lean := deg_to_rad(4.0 + 6.0 * k.rng.randf())
		var h := 2.6 + 0.8 * k.rng.randf()
		var base := d * 0.06 + Vector3(0.0, 0.14, 0.0)
		var top := base + d * sin(lean) * h + Vector3.UP * cos(lean) * h
		k.stem(base, top, 0.012, 0.005, Color(0.46, 0.4, 0.26))
		for t in 9:
			var p := base.lerp(top, 0.3 + 0.08 * float(t))
			for l in 3:
				var ld := _dir(float(t) * 2.39996 + float(s) + float(l) * 2.1)
				k.leaf(p, ld, deg_to_rad(15.0 + 15.0 * float(l)), 0.18, 0.035, 0.5,
					Color(0.38, 0.54, 0.3).lerp(Color(0.5, 0.62, 0.42), k.rng.randf()), "lance", 0.0, 2)

static func _sorghum(k: Kit) -> void:
	for b in 12:
		var d := _dir(float(b) * 2.39996)
		var pitch := deg_to_rad(lerpf(82.0, 58.0, float(b % 8) / 7.0))
		k.leaf(Vector3(0.0, 0.05 + 0.05 * float(b % 4), 0.0), d, pitch, 1.5 + 0.5 * k.rng.randf(), 0.045, 1.4,
			Color(0.3, 0.52, 0.2).lerp(Color(0.42, 0.6, 0.26), k.rng.randf()), "strap", 0.0, 5)
	for s in 4:
		var d2 := _dir(float(s) * 1.6 + 0.3)
		var top := d2 * 0.12 + Vector3(0.0, 2.15, 0.0)
		k.stem(Vector3.ZERO, top, 0.01, 0.006, Color(0.4, 0.55, 0.26))
		k.part = PART_FRUIT
		k.fruit_from = 0.6
		k.blob(top + Vector3(0.0, 0.08, 0.0), Vector3(0.035, 0.11, 0.035), Color(0.58, 0.32, 0.18), 1)
		k.part = PART_LEAF
		k.fruit_from = 0.0


## A rice hill: a tuft of narrow straps, the outer ones arching over, and
## nodding panicles that turn gold as it ripens.
static func _rice(k: Kit) -> void:
	for b in 14:
		var d := _dir(float(b) * 2.39996)
		var pitch := deg_to_rad(lerpf(84.0, 55.0, float(b % 7) / 6.0))
		k.leaf(Vector3(k.jitter(0.02), 0.0, k.jitter(0.02)), d, pitch, 0.75 + 0.25 * k.rng.randf(), 0.014, 0.9,
			Color(0.3, 0.56, 0.2).lerp(Color(0.44, 0.66, 0.26), k.rng.randf()), "strap", 0.0, 4)
	for s in 5:
		var d2 := _dir(float(s) * 1.3 + 0.4)
		var top := d2 * 0.1 + Vector3(0.0, 0.86, 0.0)
		k.part = PART_FRUIT
		k.fruit_from = 0.55
		k.leaf(top, d2, deg_to_rad(10.0), 0.2, 0.03, 1.1, Color(0.86, 0.72, 0.3), "lance", 0.0, 3)
		k.part = PART_LEAF
		k.fruit_from = 0.0


## A clump of reed culms with long leaves and a purplish-brown plume.
static func _reed(k: Kit) -> void:
	for c in 5:
		var d := _dir(float(c) * 2.39996)
		var foot := d * k.rng.randf_range(0.02, 0.1)
		var top := foot + d * 0.12 + Vector3(0.0, 2.35 + k.jitter(0.15), 0.0)
		k.stem(foot, top, 0.006, 0.004, Color(0.48, 0.58, 0.3))
		for lv in 4:
			var y := lerpf(0.5, 1.9, float(lv) / 3.0)
			var at := foot.lerp(top, y / top.y)
			k.leaf(at, _dir(float(c * 4 + lv) * 1.7), deg_to_rad(30.0), 0.45, 0.025, 0.7,
				Color(0.36, 0.52, 0.24), "strap", 0.0, 3)
		k.part = PART_FRUIT
		k.fruit_from = 0.5
		k.blob(top + Vector3(0.0, 0.12, 0.0), Vector3(0.05, 0.16, 0.05), Color(0.5, 0.36, 0.3), 1)
		k.part = PART_LEAF
		k.fruit_from = 0.0


## Taro: a few long stalks, each holding a big heart-shaped leaf.
static func _taro(k: Kit) -> void:
	for i in 5:
		var d := _dir(float(i) * 2.39996)
		var top := d * 0.22 + Vector3(0.0, 0.85 + k.jitter(0.12), 0.0)
		k.stem(Vector3.ZERO, top, 0.012, 0.008, Color(0.36, 0.48, 0.3))
		k.leaf(top, d, deg_to_rad(-12.0), 0.5, 0.36, 0.4, Color(0.24, 0.44, 0.2), "heart", 0.15, 4)


static func _dir(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))


# ---------------------------------------------------------------------------
# Mesh kit
# ---------------------------------------------------------------------------

class Kit:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var part := 0.0
	var fruit_from := 0.0
	var height := 1.0
	var rng := RandomNumberGenerator.new()

	func jitter(a: float) -> float:
		return (rng.randf() * 2.0 - 1.0) * a

	func _vert(p: Vector3, nn: Vector3, col: Color) -> void:
		v.append(p)
		n.append(nn)
		# Colours are written as seen (sRGB); the shader works in linear.
		c.append(col.srgb_to_linear())
		uv.append(Vector2(part, clampf(p.y / maxf(height, 0.01), 0.0, 1.0)))
		uv2.append(Vector2(fruit_from, 0.0))

	## One triangle, its normal turned toward `hint` (a leaf: up; a solid:
	## outward). Godot's front face is clockwise: the corners are put in that
	## order for the hinted side.
	func tri(a: Vector3, b: Vector3, cc: Vector3, col: Color, hint: Vector3) -> void:
		var nn := (b - a).cross(cc - a)
		if nn.length_squared() < 1e-14:
			return
		nn = nn.normalized()
		if nn.dot(hint) > 0.0:
			# cross(b-a, c-a) along the hint means counter-clockwise from that
			# side: swap two corners and the face turns clockwise.
			_vert(a, nn, col)
			_vert(cc, nn, col)
			_vert(b, nn, col)
		else:
			_vert(a, -nn, col)
			_vert(b, -nn, col)
			_vert(cc, -nn, col)

	## A leaf from `base` heading `d` (horizontal), rising at `pitch` and
	## curving down by `droop` radians over its length; cupped by `fold`.
	func leaf(base: Vector3, d: Vector3, pitch: float, ln: float, wd: float, droop: float,
			col: Color, shape: String, fold: float, segs: int) -> void:
		d = Vector3(d.x, 0.0, d.z).normalized()
		if d.length_squared() < 0.5:
			d = Vector3.FORWARD
		if shape == "oval" or shape == "heart" or shape == "palmate":
			segs = maxi(segs, 3)
		var side := Vector3.UP.cross(d).normalized()
		var pts: Array = [base]
		var p := base
		for i in segs:
			var t := (float(i) + 0.5) / float(segs)
			var a := pitch - droop * t
			p += (d * cos(a) + Vector3.UP * sin(a)) * (ln / float(segs))
			pts.append(p)
		for i in segs:
			var t0 := float(i) / float(segs)
			var t1 := float(i + 1) / float(segs)
			var w0 := _width(shape, t0, i) * wd * 0.5
			var w1 := _width(shape, t1, i + 1) * wd * 0.5
			var c0: Vector3 = pts[i]
			var c1: Vector3 = pts[i + 1]
			var up0 := Vector3.UP * fold * w0
			var up1 := Vector3.UP * fold * w1
			var col0 := col.darkened(0.12 * (1.0 - t0))
			var col1 := col.lightened(0.05 * t1)
			var l0 := c0 + side * w0 + up0
			var l1 := c1 + side * w1 + up1
			var r0 := c0 - side * w0 + up0
			var r1 := c1 - side * w1 + up1
			if fold <= 0.001:
				tri(r0, l0, l1, col0, Vector3.UP)
				tri(r0, l1, r1, col1, Vector3.UP)
				continue
			tri(c0, l0, c1, col0, Vector3.UP)
			tri(l0, l1, c1, col1, Vector3.UP)
			tri(c0, c1, r0, col0, Vector3.UP)
			tri(r0, c1, r1, col1, Vector3.UP)

	func _width(shape: String, t: float, i: int) -> float:
		match shape:
			"lance":
				return sin(PI * pow(t, 0.75)) * 0.8 + 0.05
			"strap":
				return 1.0 - t * 0.85
			"heart":
				return sin(PI * pow(t, 0.55)) * (1.15 - t * 0.3)
			"palmate":
				var lob := 0.85 + 0.15 * cos(float(i) * 2.4)
				return sin(PI * pow(t, 0.6)) * lob
			"wavy":
				return sin(PI * pow(t, 0.8)) * (0.75 + 0.25 * float(i % 2))
			"fern":
				return (0.3 + 0.7 * float(i % 2)) * (1.0 - t * 0.6)
			_:
				return sin(PI * pow(t, 0.8))
		return 1.0

	## A tapered four-sided stem.
	func stem(a: Vector3, b: Vector3, r0: float, r1: float, col: Color) -> void:
		var ax := b - a
		if ax.length_squared() < 1e-10:
			return
		var u := ax.normalized()
		var s1 := (Vector3.RIGHT if absf(u.dot(Vector3.UP)) > 0.9 else Vector3.UP).cross(u).normalized()
		var s2 := u.cross(s1).normalized()
		var ring := [s1, s2, -s1, -s2]
		for i in 4:
			var o0: Vector3 = ring[i]
			var o1: Vector3 = ring[(i + 1) % 4]
			var mid := (o0 + o1).normalized()
			tri(a + o0 * r0, a + o1 * r0, b + o0 * r1, col, mid)
			tri(a + o1 * r0, b + o1 * r1, b + o0 * r1, col, mid)

	## A square post (stakes, poles).
	func box(a: Vector3, b: Vector3, w: float, col: Color) -> void:
		stem(a, b, w * 0.707, w * 0.707, col)

	## A low-poly ellipsoid: detail 0 = octahedron (8 triangles), 1 = a
	## 6 x 4 lat-long (40).
	func blob(ctr: Vector3, r: Vector3, col: Color, detail: int) -> void:
		if detail <= 0:
			var px := ctr + Vector3(r.x, 0, 0)
			var nx := ctr - Vector3(r.x, 0, 0)
			var py := ctr + Vector3(0, r.y, 0)
			var ny := ctr - Vector3(0, r.y, 0)
			var pz := ctr + Vector3(0, 0, r.z)
			var nz := ctr - Vector3(0, 0, r.z)
			for f in [[px, py, pz], [pz, py, nx], [nx, py, nz], [nz, py, px],
					[pz, ny, px], [nx, ny, pz], [nz, ny, nx], [px, ny, nz]]:
				var cen: Vector3 = (f[0] + f[1] + f[2]) / 3.0
				tri(f[0], f[1], f[2], col, cen - ctr)
			return
		var segs := 6 if detail == 1 else 5
		var rings := 4 if detail == 1 else 3
		for i in rings:
			var a0 := PI * float(i) / float(rings) - PI * 0.5
			var a1 := PI * float(i + 1) / float(rings) - PI * 0.5
			for j in segs:
				var b0 := TAU * float(j) / float(segs)
				var b1 := TAU * float(j + 1) / float(segs)
				var q00 := ctr + Vector3(cos(a0) * cos(b0) * r.x, sin(a0) * r.y, cos(a0) * sin(b0) * r.z)
				var q01 := ctr + Vector3(cos(a0) * cos(b1) * r.x, sin(a0) * r.y, cos(a0) * sin(b1) * r.z)
				var q10 := ctr + Vector3(cos(a1) * cos(b0) * r.x, sin(a1) * r.y, cos(a1) * sin(b0) * r.z)
				var q11 := ctr + Vector3(cos(a1) * cos(b1) * r.x, sin(a1) * r.y, cos(a1) * sin(b1) * r.z)
				var shade := col.darkened(0.18 * (1.0 - float(i) / float(rings)))
				tri(q00, q01, q11, shade, (q00 + q01 + q11) / 3.0 - ctr)
				tri(q00, q11, q10, shade, (q00 + q11 + q10) / 3.0 - ctr)

	func commit() -> ArrayMesh:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		var m := ArrayMesh.new()
		if v.size() > 0:
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m

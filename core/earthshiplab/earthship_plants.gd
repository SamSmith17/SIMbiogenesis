class_name EarthshipPlants
extends RefCounted

## What grows in an Earthship's greenhouse beds (look only): the botanical
## cells along the glazing are watered by the house's greywater and carry
## bananas, ferns, tomatoes and peppers year round (Earthship Biotecture's
## Global Model houses; the corridor photo's Norfolk pine and ferns).
## Meshes come from GardenCrops' kit and draw with garden_crop.gdshader at
## full size (a fixed clock); the vegetables are GardenCrops' own.
##
## `scatter` lays plants along each bed at their spacing, scaled down where
## the sloped glass leaves less headroom than the plant's height.

const OWN := {
	"banana": {"spacing": 1.3, "height": 2.6, "shadow": true},
	"norfolk": {"spacing": 1.5, "height": 2.3, "shadow": true},
	"fern": {"spacing": 0.6, "height": 0.62, "shadow": false},
	"aloe": {"spacing": 0.45, "height": 0.48, "shadow": false},
	"geranium": {"spacing": 0.4, "height": 0.42, "shadow": false},
}

## Mixes: id -> weight.
const MIXES := {
	"tropical": {"banana": 0.2, "norfolk": 0.08, "fern": 0.3, "aloe": 0.14, "geranium": 0.16, "pepper_red": 0.12},
	"garden": {"tomato": 0.24, "pepper_red": 0.14, "pepper_yellow": 0.1, "kale": 0.14, "chard": 0.16,
		"basil": 0.12, "lettuce": 0.1},
	"mixed": {"banana": 0.13, "fern": 0.18, "geranium": 0.12, "tomato": 0.18, "pepper_red": 0.12,
		"chard": 0.1, "basil": 0.07, "aloe": 0.1},
}

static var _cache: Dictionary = {}


static func is_own(id: String) -> bool:
	return OWN.has(id)


static func height(id: String) -> float:
	if OWN.has(id):
		return float(OWN[id]["height"])
	return float(GardenCrops.info(id)["height"])


static func spacing(id: String) -> float:
	if OWN.has(id):
		return float(OWN[id]["spacing"])
	return GardenCrops.spacing(id) * 1.1


static func casts_shadow(id: String) -> bool:
	if OWN.has(id):
		return bool(OWN[id]["shadow"])
	return bool(GardenCrops.info(id).get("shadow", false))


static func mesh(id: String) -> ArrayMesh:
	if not OWN.has(id):
		return GardenCrops.mesh(id)
	if _cache.has(id):
		return _cache[id]
	var k := GardenCrops.Kit.new()
	k.height = height(id)
	k.rng.seed = hash(id)
	match id:
		"banana": _banana(k)
		"norfolk": _norfolk(k)
		"fern": _fern(k)
		"aloe": _aloe(k)
		_: _geranium(k)
	var m := k.commit()
	_cache[id] = m
	return m


static func _dir(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))


## A banana: a pseudostem of leaf sheaths and big paddle leaves arching out.
static func _banana(k: GardenCrops.Kit) -> void:
	var top := Vector3(0.0, 1.55, 0.0)
	k.stem(Vector3.ZERO, top, 0.11, 0.075, Color(0.42, 0.52, 0.26))
	for i in 8:
		var t := float(i) / 7.0
		var yaw := float(i) * 2.39996
		var base := top + Vector3(0.0, -0.18 * (1.0 - t), 0.0)
		var col := Color(0.24, 0.5, 0.16).lerp(Color(0.38, 0.62, 0.22), t)
		k.leaf(base, _dir(yaw), deg_to_rad(lerpf(42.0, 78.0, t)), lerpf(1.35, 0.9, t), lerpf(0.42, 0.3, t),
			lerpf(1.25, 0.6, t), col, "oval", 0.12, 6)
	# A hanging hand of fruit on some plants.
	k.part = GardenCrops.PART_FRUIT
	k.fruit_from = 0.3
	var c := top + Vector3(0.18, -0.25, 0.05)
	for j in 6:
		k.blob(c + Vector3(k.jitter(0.06), -float(j) * 0.05, k.jitter(0.06)), Vector3(0.03, 0.09, 0.03),
			Color(0.55, 0.7, 0.22), 0)
	k.part = GardenCrops.PART_LEAF
	k.fruit_from = 0.0


## A Norfolk Island pine: a straight trunk and level tiers of five branches
## carrying needle sprays.
static func _norfolk(k: GardenCrops.Kit) -> void:
	k.stem(Vector3.ZERO, Vector3(0.0, 2.25, 0.0), 0.05, 0.015, Color(0.38, 0.27, 0.18))
	var tiers := 6
	for ti in tiers:
		var t := float(ti) / float(tiers - 1)
		var y := lerpf(0.55, 2.1, t)
		var ln := lerpf(0.7, 0.22, t)
		for b in 5:
			var yaw := TAU * float(b) / 5.0 + float(ti) * 0.6
			var d := _dir(yaw)
			var tip := Vector3(0.0, y, 0.0) + d * ln + Vector3(0.0, 0.05, 0.0)
			k.stem(Vector3(0.0, y, 0.0), tip, 0.012, 0.006, Color(0.3, 0.26, 0.16))
			for s in 3:
				var p := Vector3(0.0, y, 0.0).lerp(tip, (float(s) + 1.0) / 3.5)
				for side in [-1.0, 1.0]:
					var sd: Vector3 = Vector3.UP.cross(d).normalized() * side
					k.leaf(p, (sd + d * 0.6).normalized(), deg_to_rad(10.0), 0.16 * (1.0 - t * 0.4), 0.05, 0.3,
						Color(0.16, 0.36, 0.18), "lance", 0.0, 2)


## A sword-fern clump: arching fronds of paired leaflets.
static func _fern(k: GardenCrops.Kit) -> void:
	for i in 13:
		var yaw := float(i) * 2.39996
		var t := fposmod(float(i) * 0.37, 1.0)
		k.leaf(Vector3.ZERO, _dir(yaw), deg_to_rad(lerpf(52.0, 72.0, t)), lerpf(0.72, 0.5, t), 0.16, 1.35,
			Color(0.18, 0.42, 0.16).lerp(Color(0.3, 0.55, 0.2), t), "fern", 0.0, 8)


## An aloe: a rosette of thick, grey-green straps.
static func _aloe(k: GardenCrops.Kit) -> void:
	for i in 14:
		var t := float(i) / 13.0
		var yaw := float(i) * 2.39996
		k.leaf(Vector3(0.0, 0.03, 0.0), _dir(yaw), deg_to_rad(lerpf(35.0, 75.0, t)), lerpf(0.42, 0.25, t),
			lerpf(0.08, 0.06, t), 0.3, Color(0.42, 0.56, 0.42).lerp(Color(0.5, 0.62, 0.45), t), "strap", 0.5, 3)


## A geranium: a mound of round leaves under red flower heads.
static func _geranium(k: GardenCrops.Kit) -> void:
	for i in 12:
		var yaw := float(i) * 2.39996
		var t := float(i) / 11.0
		k.leaf(Vector3(0.0, 0.05 + 0.12 * t, 0.0), _dir(yaw), deg_to_rad(lerpf(25.0, 55.0, t)), 0.16, 0.13, 0.4,
			Color(0.24, 0.46, 0.18), "heart", 0.2, 3)
	k.part = GardenCrops.PART_FRUIT
	k.fruit_from = 0.1
	for f in 5:
		var yaw2 := float(f) * 1.26
		var p := _dir(yaw2) * 0.1 + Vector3(0.0, 0.36 + k.jitter(0.04), 0.0)
		k.stem(Vector3(0.0, 0.15, 0.0), p, 0.004, 0.003, Color(0.3, 0.45, 0.2))
		for b in 4:
			k.blob(p + Vector3(k.jitter(0.03), k.jitter(0.015), k.jitter(0.03)), Vector3(0.025, 0.02, 0.025),
				Color(0.88, 0.12, 0.16), 0)
	k.part = GardenCrops.PART_LEAF
	k.fruit_from = 0.0


## Plants along each bed: id -> Array of Transform3D (spec frame, metres).
## Pure and deterministic for a seed.
static func scatter(planters: Array, mix_id: String, seed: int) -> Dictionary:
	var out := {}
	var mix: Dictionary = MIXES.get(mix_id, {})
	if mix.is_empty():
		return out
	var ids: Array = mix.keys()
	ids.sort()
	var total := 0.0
	for id in ids:
		total += float(mix[id])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for pl in planters:
		var p: Dictionary = pl
		var x := float(p["x0"])
		var x_end := float(p["x1"])
		var z0 := float(p["z0"])
		var z1 := float(p["z1"])
		while x < x_end:
			var r := rng.randf() * total
			var pick: String = ids[0]
			for id2 in ids:
				r -= float(mix[id2])
				if r <= 0.0:
					pick = id2
					break
			var sp := spacing(pick)
			var px := x + sp * 0.5
			if px > x_end:
				break
			var pz := lerpf(z0, z1, rng.randf_range(0.2, 0.8)) if z1 > z0 else (z0 + z1) * 0.5
			# Headroom under the glass where it stands.
			var u := 0.0 if z1 <= z0 else (pz - z0) / (z1 - z0)
			var head := lerpf(float(p.get("head0", 3.0)), float(p.get("head1", 3.0)), u)
			var sc := rng.randf_range(0.82, 1.08)
			sc = minf(sc, head / height(pick))
			if sc > 0.25:
				var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc)
				if not out.has(pick):
					out[pick] = []
				(out[pick] as Array).append(Transform3D(b, Vector3(px, float(p["y"]), pz)))
			x += sp * rng.randf_range(0.75, 1.0)
	return out

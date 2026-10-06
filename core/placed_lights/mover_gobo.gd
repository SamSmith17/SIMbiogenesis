class_name MoverGobo
extends RefCounted

## Procedural gobos for moving-head spots and gobo projectors, used as a
## SpotLight3D `light_projector` (Forward+ supports projector textures; the
## light's colour multiplies the pattern). Generated once per pattern and
## cached — nothing ships as an image asset, so there is nothing to licence.
## White = light passes, black = steel.

const SIZE := 128

static var _cache: Dictionary = {}


static func texture(pattern: String) -> Texture2D:
	if pattern.is_empty() or pattern == "none":
		return null
	if _cache.has(pattern):
		return _cache[pattern]
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var u := (float(x) + 0.5) / float(SIZE) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(SIZE) * 2.0 - 1.0
			var a := alpha(pattern, u, v)
			img.set_pixel(x, y, Color(a, a, a, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_cache[pattern] = tex
	return tex


## Coverage of the gobo at (u, v) in [-1, 1]² (pure — the selftest samples it).
static func alpha(pattern: String, u: float, v: float) -> float:
	var r := sqrt(u * u + v * v)
	if r > 1.0:
		return 0.0   # the round aperture of the lens
	var edge := 1.0 - smoothstep(0.9, 1.0, r)
	match pattern:
		"dots":
			# A ring of 8 dots round a centre dot — the classic party projector.
			var best := Vector2(u, v).length()
			for k in 8:
				var ang := TAU * float(k) / 8.0
				best = minf(best, Vector2(u - 0.6 * cos(ang), v - 0.6 * sin(ang)).length())
			return edge * (1.0 - smoothstep(0.12, 0.16, best))
		"star":
			var ang2 := atan2(v, u)
			var limb := 0.35 + 0.55 * pow(absf(cos(ang2 * 2.5)), 6.0)
			return edge * (1.0 - smoothstep(limb - 0.05, limb, r))
		"breakup":
			# Leafy breakup: thresholded value noise (two octaves, hashed lattice).
			var n := 0.65 * _vnoise(u * 3.0, v * 3.0) + 0.35 * _vnoise(u * 7.0 + 3.1, v * 7.0 - 1.7)
			return edge * smoothstep(0.48, 0.56, n)
		"rings":
			return edge * (1.0 - smoothstep(0.35, 0.65, absf(sin(r * 14.0))))
		"bars":
			return edge * (1.0 - smoothstep(0.3, 0.6, absf(sin(u * 11.0))))
		_:
			return edge


static func _hash2(x: float, y: float) -> float:
	return fposmod(sin(x * 127.1 + y * 311.7) * 43758.5453, 1.0)


static func _vnoise(x: float, y: float) -> float:
	var ix := floorf(x)
	var iy := floorf(y)
	var fx := x - ix
	var fy := y - iy
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := _hash2(ix, iy)
	var b := _hash2(ix + 1.0, iy)
	var c := _hash2(ix, iy + 1.0)
	var d := _hash2(ix + 1.0, iy + 1.0)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)

class_name StructureMaterials
extends Object

## Shared procedural PBR materials for generated structures (Pallet Rack, Linkage
## Lab, and future builders). Fixes the two problems the flat/dark look came from:
##
##  1. DARKNESS — painted steel was authored at high `metallic` (0.6–0.9). A
##     metallic surface has no diffuse term, so wherever it is self-shadowed or
##     occluded (rack interiors) it collapses to near-black while the low-metallic
##     wood stays lit. Painted/coated metal is physically a DIELECTRIC, so we drop
##     metallic to ~0.1 and let albedo carry the colour; it now reads under ambient
##     even in shadow. Bare hardware keeps some metallic but high roughness so it
##     never becomes a black mirror.
##
##  2. FLATNESS — bare colour with no texture. We add procedural grain + surface
##     relief with cached NoiseTexture2D maps, triplanar-projected so the tiling is
##     consistent across faces of any size WITHOUT needing good UVs on the built
##     geometry. Cost is a few extra texture samples on structure surfaces only —
##     no per-frame work, no custom shaders. Metal kinds get a normal map only
##     (uniform colour); wood/ply also get a subtle albedo-variation map.

enum Kind { PAINTED_METAL, HARDWARE_METAL, WOOD, PLYWOOD, PANEL, GALVANISED, ALUMINIUM, PLASTIC, GLAZING, FABRIC, WEATHERING_STEEL }

## NoiseTexture2D cache keyed by a descriptor string — one small texture per unique
## (kind, role) reused by every material instance.
static var _tex_cache: Dictionary = {}


static func make(kind: int, base_color: Color, world_triplanar: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base_color
	# Preserve the builders' existing double-sided behaviour (mirrored struts /
	# open frames must never read as see-through).
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world_triplanar
	m.uv1_triplanar_sharpness = 0.6

	match kind:
		Kind.PAINTED_METAL:
			m.metallic = 0.12
			m.metallic_specular = 0.55
			m.roughness = 0.48
			m.uv1_scale = Vector3(1.4, 1.4, 1.4)
			_apply_normal(m, "paint", 0.06, 0.9)
		Kind.HARDWARE_METAL:
			# Dull zinc/galvanised hardware — metallic but rough enough that occluded
			# faces scatter ambient instead of going black.
			m.metallic = 0.55
			m.metallic_specular = 0.5
			m.roughness = 0.62
			m.uv1_scale = Vector3(2.2, 2.2, 2.2)
			_apply_normal(m, "hardware", 0.05, 1.6)
		Kind.WOOD:
			m.metallic = 0.0
			m.metallic_specular = 0.3
			m.roughness = 0.82
			m.uv1_scale = Vector3(1.8, 1.8, 1.8)
			# Keep it close to a flat light brown — only a whisper of grain so it
			# reads as painted/sanded lumber, not mottled/noisy.
			_apply_albedo_grain(m, "wood", 0.92, 1.0, 2.0)
			_apply_normal(m, "wood", 0.05, 2.0)
		Kind.PLYWOOD:
			m.metallic = 0.0
			m.metallic_specular = 0.35
			m.roughness = 0.8
			m.uv1_scale = Vector3(1.5, 1.5, 1.5)
			_apply_albedo_grain(m, "plywood", 0.78, 1.0, 1.6)
			_apply_normal(m, "plywood", 0.12, 1.8)
		Kind.PANEL:
			# PV cell face — dark, glassy, low roughness (a touch of metallic reads as
			# the AR-coated glass). Kept mostly smooth; no grain.
			m.metallic = 0.15
			m.metallic_specular = 0.6
			m.roughness = 0.18
			m.uv1_scale = Vector3(4.0, 4.0, 4.0)
		Kind.GALVANISED:
			# Bare hot-dip zinc (EMT conduit, fence pipe): a dull metal mottled by
			# its spangle, never a mirror.
			m.metallic = 0.72
			m.metallic_specular = 0.5
			m.roughness = 0.52
			m.uv1_scale = Vector3(2.4, 2.4, 2.4)
			_apply_albedo_grain(m, "galv", 0.88, 1.0, 2.6)
			_apply_normal(m, "hardware", 0.04, 1.6)
		Kind.ALUMINIUM:
			# Mill-finish aluminium: brighter and smoother than zinc.
			m.metallic = 0.8
			m.metallic_specular = 0.55
			m.roughness = 0.38
			m.uv1_scale = Vector3(2.0, 2.0, 2.0)
			_apply_normal(m, "paint", 0.03, 1.2)
		Kind.PLASTIC:
			# Extruded or moulded polymer (PVC, HDPE, PP): a dielectric with a
			# soft sheen and no grain.
			m.metallic = 0.0
			m.metallic_specular = 0.5
			m.roughness = 0.58
		Kind.GLAZING:
			# Clear sheet (polycarbonate, acrylic): glossy dielectric. The caller
			# sets the alpha and the transparency mode.
			m.metallic = 0.0
			m.metallic_specular = 0.7
			m.roughness = 0.1
		Kind.WEATHERING_STEEL:
			# Corten: a matte rust patina, mottled orange-brown, no metal sheen.
			m.metallic = 0.08
			m.metallic_specular = 0.35
			m.roughness = 0.88
			m.uv1_scale = Vector3(1.2, 1.2, 1.2)
			_apply_albedo_grain(m, "corten", 0.62, 1.0, 1.4)
			_apply_normal(m, "corten", 0.18, 2.4)
		Kind.FABRIC:
			# Tarp, canvas, shade cloth: fully matte with a faint weave.
			m.metallic = 0.0
			m.metallic_specular = 0.15
			m.roughness = 0.96
			m.uv1_scale = Vector3(6.0, 6.0, 6.0)
			_apply_albedo_grain(m, "fabric", 0.9, 1.0, 5.0)
	return m


## Subtle grayscale albedo variation (multiplies albedo_color). `lo`..`hi` remaps
## the noise so it only darkens slightly; `freq` sets grain scale (higher = finer).
static func _apply_albedo_grain(m: StandardMaterial3D, role: String,
		lo: float, hi: float, freq: float) -> void:
	m.albedo_texture = _noise_tex("alb_%s" % role, freq, false, 0.0, lo, hi)


static func _apply_normal(m: StandardMaterial3D, role: String,
		strength: float, freq: float) -> void:
	m.normal_enabled = true
	m.normal_scale = strength
	m.normal_texture = _noise_tex("nrm_%s" % role, freq, true, 1.0, 0.0, 1.0)


static func _noise_tex(key: String, freq: float, as_normal: bool,
		bump: float, ramp_lo: float, ramp_hi: float) -> NoiseTexture2D:
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = hash(key) & 0x7fffffff
	n.frequency = freq * 0.01
	n.fractal_octaves = 3
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.generate_mipmaps = true
	if as_normal:
		t.as_normal_map = true
		t.bump_strength = bump
	else:
		var g := Gradient.new()
		g.set_color(0, Color(ramp_lo, ramp_lo, ramp_lo))
		g.set_color(1, Color(ramp_hi, ramp_hi, ramp_hi))
		t.color_ramp = g
	t.noise = n
	_tex_cache[key] = t
	return t

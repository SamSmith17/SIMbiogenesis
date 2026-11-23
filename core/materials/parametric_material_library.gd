class_name ParametricMaterialLibrary
extends RefCounted

## Central reusable PBR material library for all parametrically generated models.
##
## Features:
##   1. 20 reusable common engineering & architectural materials (plywood, lumber,
##      powder-coated metal, mill aluminum, copper, brass/bronze, stainless,
##      galvanized steel, hardware steel, Corten weathering steel, corrugated
##      metal roofing, solar reflector, PMMA/acrylic, glass, PV silicon cell,
##      molded plastics, EPDM rubber, technical fabric, concrete/earth, car paint),
##      plus user-created custom entries.
##   2. Hybrid texture pipeline:
##      - Auto-discovers drop-in CC0 PBR texture sets placed under
##        `res://assets/materials/<id>/` (plus existing project textures such as
##        `ground049a`, `ground088`, and `Wood034_1K-JPG` when present).
##      - Synthesizes directional / cellular / ribbed procedural PBR maps
##        (albedo grain + tangent normal + micro-roughness + AO) via
##        `ParametricMaterialSynth` whenever a slot has no image file.
##      - Supports user-uploaded custom textures (`user://materials/textures/<id>/`)
##        with optional single-photo normal/roughness derivation and tint-neutral
##        grain normalization so parametric part colors tint cleanly.
##   3. Live `WeakRef` instance registry: tuning any slider or uploading a texture
##      in `MaterialLibraryModal` updates every live `StandardMaterial3D` in the
##      running 3D world in place without rebuilding meshes.

const DEFAULT_STORE_ROOT := "user://materials"
const LIBRARY_JSON := "library.json"
const TEXTURES_SUBDIR := "textures"
const IMAGE_EXTS := ["jpg", "jpeg", "png", "webp"]
const MAP_SLOTS := ["albedo", "normal", "roughness", "ao"]

const ORDER: Array[String] = [
	"plywood", "lumber",
	"powder_coat", "aluminium", "copper", "brass_bronze", "stainless",
	"galvanised", "hardware_steel", "corten", "metal_roofing", "reflector",
	"pmma", "glass", "pv_cell",
	"plastic", "rubber", "fabric", "car_paint",
	"concrete",
]

const BUILTIN_SPECS: Dictionary = {
	"plywood": {
		"label": "Plywood",
		"category": "Wood & Biomass",
		"pattern": "plywood_veneer",
		"default_color": Color(0.80, 0.66, 0.44),
		"metallic": 0.0,
		"roughness": 0.68,
		"specular": 0.40,
		"normal_scale": 0.85,
		"grain_strength": 0.68,
		"rough_contrast": 0.58,
		"ao_strength": 0.28,
		"clearcoat": 0.08,
		"clearcoat_roughness": 0.42,
		"scale_m": 0.65,
	},
	"lumber": {
		"label": "Dimensional Lumber",
		"category": "Wood & Biomass",
		"pattern": "wood_grain",
		"default_color": Color(0.70, 0.53, 0.34),
		"metallic": 0.0,
		"roughness": 0.74,
		"specular": 0.36,
		"normal_scale": 0.85,
		"grain_strength": 0.62,
		"rough_contrast": 0.58,
		"ao_strength": 0.28,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.5,
		"scale_m": 0.55,
	},
	"powder_coat": {
		"label": "Powder-Coated Metal",
		"category": "Metals & Coatings",
		"pattern": "powder_coat",
		"default_color": Color(0.20, 0.44, 0.52),
		"metallic": 0.22,
		"roughness": 0.34,
		"specular": 0.64,
		"normal_scale": 0.48,
		"grain_strength": 0.16,
		"rough_contrast": 0.48,
		"ao_strength": 0.0,
		"clearcoat": 0.35,
		"clearcoat_roughness": 0.22,
		"scale_m": 0.30,
	},
	"aluminium": {
		"label": "Mill Aluminum",
		"category": "Metals & Coatings",
		"pattern": "brushed_metal",
		"default_color": Color(0.80, 0.82, 0.85),
		"metallic": 0.82,
		"roughness": 0.34,
		"specular": 0.62,
		"normal_scale": 0.22,
		"grain_strength": 0.18,
		"rough_contrast": 0.45,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.3,
		"scale_m": 0.45,
	},
	"copper": {
		"label": "Copper",
		"category": "Metals & Coatings",
		"pattern": "brushed_metal",
		"default_color": Color(0.92, 0.55, 0.38),
		"metallic": 0.88,
		"roughness": 0.28,
		"specular": 0.68,
		"normal_scale": 0.20,
		"grain_strength": 0.16,
		"rough_contrast": 0.42,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.25,
		"scale_m": 0.40,
	},
	"brass_bronze": {
		"label": "Brass & Bronze",
		"category": "Metals & Coatings",
		"pattern": "brushed_metal",
		"default_color": Color(0.84, 0.68, 0.36),
		"metallic": 0.84,
		"roughness": 0.32,
		"specular": 0.64,
		"normal_scale": 0.22,
		"grain_strength": 0.18,
		"rough_contrast": 0.40,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.3,
		"scale_m": 0.35,
	},
	"stainless": {
		"label": "Brushed Stainless",
		"category": "Metals & Coatings",
		"pattern": "brushed_metal",
		"default_color": Color(0.78, 0.79, 0.81),
		"metallic": 0.80,
		"roughness": 0.28,
		"specular": 0.65,
		"normal_scale": 0.20,
		"grain_strength": 0.16,
		"rough_contrast": 0.42,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.25,
		"scale_m": 0.35,
	},
	"galvanised": {
		"label": "Galvanized Steel",
		"category": "Metals & Coatings",
		"pattern": "galvanized_spangle",
		"default_color": Color(0.66, 0.68, 0.70),
		"metallic": 0.72,
		"roughness": 0.50,
		"specular": 0.54,
		"normal_scale": 0.26,
		"grain_strength": 0.34,
		"rough_contrast": 0.62,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.4,
		"scale_m": 0.42,
	},
	"hardware_steel": {
		"label": "Hardware & Structural Steel",
		"category": "Metals & Coatings",
		"pattern": "powder_coat",
		"default_color": Color(0.50, 0.52, 0.55),
		"metallic": 0.60,
		"roughness": 0.54,
		"specular": 0.52,
		"normal_scale": 0.25,
		"grain_strength": 0.18,
		"rough_contrast": 0.42,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.4,
		"scale_m": 0.38,
	},
	"corten": {
		"label": "Corten Weathering Steel",
		"category": "Metals & Coatings",
		"pattern": "corten_rust",
		"default_color": Color(0.62, 0.31, 0.16),
		"metallic": 0.10,
		"roughness": 0.86,
		"specular": 0.34,
		"normal_scale": 0.65,
		"grain_strength": 0.58,
		"rough_contrast": 0.60,
		"ao_strength": 0.45,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.6,
		"scale_m": 0.85,
	},
	"metal_roofing": {
		"label": "Corrugated Metal Roofing",
		"category": "Metals & Coatings",
		"pattern": "corrugated_metal",
		"default_color": Color(0.60, 0.63, 0.66),
		"metallic": 0.58,
		"roughness": 0.44,
		"specular": 0.58,
		"normal_scale": 0.85,
		"grain_strength": 0.24,
		"rough_contrast": 0.42,
		"ao_strength": 0.55,
		"clearcoat": 0.12,
		"clearcoat_roughness": 0.30,
		"scale_m": 0.50,
	},
	"reflector": {
		"label": "Solar Reflector",
		"category": "Glazing & Optics",
		"pattern": "smooth_glass",
		"default_color": Color(0.93, 0.95, 0.97),
		"metallic": 0.94,
		"roughness": 0.06,
		"specular": 0.92,
		"normal_scale": 0.04,
		"grain_strength": 0.04,
		"rough_contrast": 0.12,
		"ao_strength": 0.0,
		"clearcoat": 0.35,
		"clearcoat_roughness": 0.04,
		"scale_m": 1.20,
	},
	"pmma": {
		"label": "PMMA / Cast Acrylic",
		"category": "Glazing & Optics",
		"pattern": "smooth_glass",
		"default_color": Color(0.84, 0.90, 0.95, 0.38),
		"metallic": 0.0,
		"roughness": 0.08,
		"specular": 0.78,
		"normal_scale": 0.05,
		"grain_strength": 0.0,
		"rough_contrast": 0.10,
		"ao_strength": 0.0,
		"clearcoat": 0.65,
		"clearcoat_roughness": 0.05,
		"scale_m": 1.00,
	},
	"glass": {
		"label": "Architectural Glass",
		"category": "Glazing & Optics",
		"pattern": "smooth_glass",
		"default_color": Color(0.76, 0.88, 0.94, 0.32),
		"metallic": 0.05,
		"roughness": 0.06,
		"specular": 0.88,
		"normal_scale": 0.03,
		"grain_strength": 0.0,
		"rough_contrast": 0.08,
		"ao_strength": 0.0,
		"clearcoat": 0.85,
		"clearcoat_roughness": 0.03,
		"scale_m": 1.40,
	},
	"pv_cell": {
		"label": "Solar PV Silicon Cell",
		"category": "Glazing & Optics",
		"pattern": "pv_cell",
		"default_color": Color(0.06, 0.10, 0.20),
		"metallic": 0.16,
		"roughness": 0.16,
		"specular": 0.72,
		"normal_scale": 0.14,
		"grain_strength": 0.25,
		"rough_contrast": 0.30,
		"ao_strength": 0.0,
		"clearcoat": 0.75,
		"clearcoat_roughness": 0.08,
		"scale_m": 0.25,
	},
	"plastic": {
		"label": "Molded Plastic (HDPE / ABS)",
		"category": "Polymers & Textiles",
		"pattern": "molded_plastic",
		"default_color": Color(0.16, 0.42, 0.74),
		"metallic": 0.0,
		"roughness": 0.52,
		"specular": 0.50,
		"normal_scale": 0.22,
		"grain_strength": 0.10,
		"rough_contrast": 0.35,
		"ao_strength": 0.0,
		"clearcoat": 0.08,
		"clearcoat_roughness": 0.38,
		"scale_m": 0.28,
	},
	"rubber": {
		"label": "EPDM Rubber & Silicone",
		"category": "Polymers & Textiles",
		"pattern": "molded_plastic",
		"default_color": Color(0.14, 0.14, 0.15),
		"metallic": 0.0,
		"roughness": 0.84,
		"specular": 0.26,
		"normal_scale": 0.26,
		"grain_strength": 0.14,
		"rough_contrast": 0.32,
		"ao_strength": 0.0,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.6,
		"scale_m": 0.24,
	},
	"fabric": {
		"label": "Technical Fabric & Canvas",
		"category": "Polymers & Textiles",
		"pattern": "fabric_weave",
		"default_color": Color(0.86, 0.82, 0.74),
		"metallic": 0.0,
		"roughness": 0.94,
		"specular": 0.18,
		"normal_scale": 0.48,
		"grain_strength": 0.32,
		"rough_contrast": 0.30,
		"ao_strength": 0.35,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.8,
		"scale_m": 0.18,
	},
	"car_paint": {
		"label": "Automotive Clearcoat",
		"category": "Polymers & Textiles",
		"pattern": "powder_coat",
		"default_color": Color(0.76, 0.78, 0.80),
		"metallic": 0.18,
		"roughness": 0.32,
		"specular": 0.62,
		"normal_scale": 0.10,
		"grain_strength": 0.06,
		"rough_contrast": 0.20,
		"ao_strength": 0.0,
		"clearcoat": 0.75,
		"clearcoat_roughness": 0.10,
		"scale_m": 0.30,
	},
	"concrete": {
		"label": "Concrete & Rammed Earth",
		"category": "Mineral & Masonry",
		"pattern": "concrete_earth",
		"default_color": Color(0.62, 0.60, 0.56),
		"metallic": 0.0,
		"roughness": 0.90,
		"specular": 0.24,
		"normal_scale": 0.62,
		"grain_strength": 0.45,
		"rough_contrast": 0.48,
		"ao_strength": 0.40,
		"clearcoat": 0.0,
		"clearcoat_roughness": 0.7,
		"scale_m": 0.90,
	},
}

## Existing project PBR texture fallbacks (used automatically in `auto` mode
## unless overridden by a dedicated `res://assets/materials/<id>/` CC0 folder).
const PROJECT_CC0_FALLBACKS: Dictionary = {
	"lumber": {
		"albedo": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_Color.jpg",
		"normal": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_NormalGL.jpg",
		"roughness": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_Roughness.jpg",
	},
	"plywood": {
		"albedo": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_Color.jpg",
		"normal": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_NormalGL.jpg",
		"roughness": "res://Imported Models/Materials/Wood034_1K-JPG/Wood034_1K-JPG_Roughness.jpg",
	},
	"concrete": {
		"albedo": "res://core/terrain/textures/ground049a/ground049a_color.jpg",
		"normal": "res://core/terrain/textures/ground049a/ground049a_normal.jpg",
		"roughness": "res://core/terrain/textures/ground049a/ground049a_roughness.jpg",
	},
	"corten": {
		"normal": "res://assets/materials/ground088/Ground088_1K-JPG_NormalGL.jpg",
		"roughness": "res://assets/materials/ground088/Ground088_1K-JPG_Roughness.jpg",
		"ao": "res://assets/materials/ground088/Ground088_1K-JPG_AmbientOcclusion.jpg",
	},
}

static var _store_root: String = DEFAULT_STORE_ROOT
static var _loaded: bool = false
static var _overrides: Dictionary = {}       # mat_id -> Dictionary of user overrides
static var _custom_defs: Dictionary = {}     # user_<slug> -> Dictionary spec
static var _cc0_cache: Dictionary = {}       # mat_id -> {slot: res_path}
static var _user_tex_cache: Dictionary = {}  # user_path -> ImageTexture
static var _res_tex_cache: Dictionary = {}   # res_path -> Texture2D
static var _live_instances: Dictionary = {}  # mat_id -> Array[WeakRef]


## Redirect persistence root (used by offline selftests so `user://materials` stays untouched).
static func set_store_root(root: String) -> void:
	_store_root = root if not root.is_empty() else DEFAULT_STORE_ROOT
	_loaded = false
	_overrides.clear()
	_custom_defs.clear()
	_user_tex_cache.clear()
	_ensure_loaded()


static func get_store_root() -> String:
	return _store_root


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var p := _store_root.path_join(LIBRARY_JSON)
	if not FileAccess.file_exists(p):
		return
	var txt := FileAccess.get_file_as_string(p)
	if txt.is_empty():
		return
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return
	var d := parsed as Dictionary
	if d.get("overrides") is Dictionary:
		_overrides = (d["overrides"] as Dictionary).duplicate(true)
	if d.get("custom_defs") is Dictionary:
		for cid in (d["custom_defs"] as Dictionary).keys():
			var raw: Variant = d["custom_defs"][cid]
			if raw is Dictionary:
				_custom_defs[str(cid)] = _deserialize_spec(raw as Dictionary)


static func save() -> void:
	_ensure_loaded()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_store_root))
	var cdefs := {}
	for cid in _custom_defs.keys():
		cdefs[cid] = _serialize_spec(_custom_defs[cid] as Dictionary)
	var out := {
		"version": 1,
		"overrides": _overrides,
		"custom_defs": cdefs,
	}
	var f := FileAccess.open(_store_root.path_join(LIBRARY_JSON), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "\t"))
		f.close()


## Ordered list of all available material IDs (built-ins in `ORDER` + custom entries).
static func all_ids() -> Array[String]:
	_ensure_loaded()
	var ids: Array[String] = []
	for id in ORDER:
		ids.append(id)
	var extra: Array = _custom_defs.keys()
	extra.sort()
	for cid in extra:
		var s := str(cid)
		if not ids.has(s):
			ids.append(s)
	return ids


static func has_material(mat_id: String) -> bool:
	_ensure_loaded()
	return BUILTIN_SPECS.has(mat_id) or _custom_defs.has(mat_id)


static func is_custom_material(mat_id: String) -> bool:
	_ensure_loaded()
	return _custom_defs.has(mat_id) and not BUILTIN_SPECS.has(mat_id)


static func is_modified(mat_id: String) -> bool:
	_ensure_loaded()
	return _overrides.has(mat_id) and not (_overrides[mat_id] as Dictionary).is_empty()


## Base default spec before user overrides.
static func default_spec(mat_id: String) -> Dictionary:
	_ensure_loaded()
	var base: Dictionary = {}
	if BUILTIN_SPECS.has(mat_id):
		base = (BUILTIN_SPECS[mat_id] as Dictionary).duplicate(true)
	elif _custom_defs.has(mat_id):
		base = (_custom_defs[mat_id] as Dictionary).duplicate(true)
	else:
		base = (BUILTIN_SPECS["powder_coat"] as Dictionary).duplicate(true)
	base["id"] = mat_id
	if not base.has("texture_mode"):
		base["texture_mode"] = "auto"
	if not base.has("derive_maps"):
		base["derive_maps"] = true
	if not base.has("full_color_albedo"):
		base["full_color_albedo"] = false
	if not base.has("custom_textures"):
		base["custom_textures"] = {}
	return base


## Resolved effective spec (`default_spec` merged with user `_overrides`).
static func resolved_spec(mat_id: String) -> Dictionary:
	var spec := default_spec(mat_id)
	if _overrides.has(mat_id):
		var ov := _overrides[mat_id] as Dictionary
		for k in ov.keys():
			if k == "default_color" and ov[k] is String:
				spec[k] = Color.from_string(str(ov[k]), spec.get("default_color", Color.GRAY))
			elif k == "custom_textures" and ov[k] is Dictionary:
				spec["custom_textures"] = (ov[k] as Dictionary).duplicate(true)
			else:
				spec[k] = ov[k]
	return spec


## Describe where the active textures for `mat_id` come from (`"custom"`, `"cc0"`, or `"procedural"`).
static func active_source_kind(mat_id: String) -> String:
	var spec := resolved_spec(mat_id)
	var mode := str(spec.get("texture_mode", "auto"))
	var ctex: Dictionary = spec.get("custom_textures", {})
	if mode == "custom" and not ctex.is_empty():
		return "custom"
	if mode == "procedural":
		return "procedural"
	var cc0 := resolve_cc0_paths(mat_id)
	if not cc0.is_empty():
		return "cc0"
	return "procedural"


## Discover CC0 texture files for `mat_id`:
##   1) Drop-in folder `res://assets/materials/<mat_id>/` (export-safe `.import`/`.remap` stripping).
##   2) Existing project PBR fallbacks (`PROJECT_CC0_FALLBACKS`) when present on disk.
static func resolve_cc0_paths(mat_id: String) -> Dictionary:
	if _cc0_cache.has(mat_id):
		return _cc0_cache[mat_id]
	var found := _scan_cc0_folder("res://assets/materials/" + mat_id)
	if found.is_empty() and PROJECT_CC0_FALLBACKS.has(mat_id):
		var fb := PROJECT_CC0_FALLBACKS[mat_id] as Dictionary
		for slot in fb.keys():
			var p := str(fb[slot])
			if ResourceLoader.exists(p):
				found[slot] = p
	_cc0_cache[mat_id] = found
	return found


static func refresh_cc0_discovery() -> void:
	_cc0_cache.clear()
	for id in all_ids():
		reapply_live(id)


static func _scan_cc0_folder(dir_path: String) -> Dictionary:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return {}
	var out := {}
	dir.list_dir_begin()
	while true:
		var fn := dir.get_next()
		if fn.is_empty():
			break
		if dir.current_is_dir() or fn.begins_with("."):
			continue
		var clean := fn.trim_suffix(".import").trim_suffix(".remap")
		var ext := clean.get_extension().to_lower()
		if not IMAGE_EXTS.has(ext):
			continue
		var stem := clean.get_basename().to_lower()
		var full := dir_path.path_join(clean)
		if not ResourceLoader.exists(full):
			continue
		if stem.contains("normaldx"):
			continue # Prefer OpenGL (+Y) normal maps in Godot.
		if stem.contains("normal") or stem.ends_with("_nrm") or stem == "nrm":
			out["normal"] = full
		elif stem.contains("rough") or stem.ends_with("_rgh") or stem == "rgh":
			out["roughness"] = full
		elif stem.contains("ambientocclusion") or stem.ends_with("_ao") or stem == "ao":
			out["ao"] = full
		elif stem.contains("color") or stem.contains("albedo") or stem.contains("diff") or stem == "base":
			out["albedo"] = full
	dir.list_dir_end()
	return out


## Build a new `StandardMaterial3D` for `mat_id` tinted with `base_color` and
## register a `WeakRef` so live edits in `MaterialLibraryModal` update it in place.
## `opts` supports: `world_triplanar` (bool), `vertex_color` (bool), `cull_mode` (int), `alpha` (float).
static func make(mat_id: String, base_color: Color = Color(1, 1, 1, -1), opts: Dictionary = {}) -> StandardMaterial3D:
	_ensure_loaded()
	var use_id := mat_id if has_material(mat_id) else "powder_coat"
	var spec := resolved_spec(use_id)
	var col := base_color
	if col.a < 0.0:
		col = spec.get("default_color", Color.WHITE)
	if opts.has("alpha"):
		col.a = float(opts["alpha"])
	var m := StandardMaterial3D.new()
	m.cull_mode = int(opts.get("cull_mode", BaseMaterial3D.CULL_DISABLED))
	m.uv1_triplanar = true
	m.uv1_world_triplanar = bool(opts.get("world_triplanar", false))
	m.uv1_triplanar_sharpness = 0.75
	if bool(opts.get("vertex_color", false)):
		m.vertex_color_use_as_albedo = true
	if col.a < 0.999:
		m.transparency = int(opts.get("transparency", BaseMaterial3D.TRANSPARENCY_ALPHA))
	m.set_meta("pmat_id", use_id)
	m.set_meta("pmat_base_color", col)
	_apply_spec_to_material(m, use_id, spec)
	_register_live(use_id, m)
	return m


static func _apply_spec_to_material(m: StandardMaterial3D, mat_id: String, spec: Dictionary) -> void:
	var base_col: Color = m.get_meta("pmat_base_color", spec.get("default_color", Color.WHITE))
	var full_rgb := bool(spec.get("full_color_albedo", false))
	if full_rgb and active_source_kind(mat_id) != "procedural" and not m.vertex_color_use_as_albedo:
		m.albedo_color = Color(1.0, 1.0, 1.0, base_col.a)
	else:
		m.albedo_color = base_col

	m.metallic = clampf(float(spec.get("metallic", 0.0)), 0.0, 1.0)
	m.metallic_specular = clampf(float(spec.get("specular", 0.5)), 0.0, 1.0)
	m.roughness = clampf(float(spec.get("roughness", 0.5)), 0.02, 1.0)

	var scale_m := maxf(float(spec.get("scale_m", 0.5)), 0.05)
	var inv_s := 1.0 / scale_m
	m.uv1_scale = Vector3(inv_s, inv_s, inv_s)

	var cc := clampf(float(spec.get("clearcoat", 0.0)), 0.0, 1.0)
	m.clearcoat_enabled = cc > 0.01
	if m.clearcoat_enabled:
		m.clearcoat = cc
		m.clearcoat_roughness = clampf(float(spec.get("clearcoat_roughness", 0.15)), 0.01, 1.0)

	var maps := _resolve_textures(mat_id, spec)
	var grain_s := clampf(float(spec.get("grain_strength", 0.3)), 0.0, 1.0)
	var alb_tex: Texture2D = maps.get("albedo")
	if alb_tex != null and (grain_s > 0.01 or full_rgb):
		m.albedo_texture = alb_tex
	else:
		m.albedo_texture = null

	var nrm_s := clampf(float(spec.get("normal_scale", 0.3)), 0.0, 2.5)
	var nrm_tex: Texture2D = maps.get("normal")
	m.normal_enabled = nrm_tex != null and nrm_s > 0.005
	if m.normal_enabled:
		m.normal_texture = nrm_tex
		m.normal_scale = nrm_s
	else:
		m.normal_texture = null

	var rgh_c := clampf(float(spec.get("rough_contrast", 0.4)), 0.0, 1.0)
	var rgh_tex: Texture2D = maps.get("roughness")
	if rgh_tex != null and rgh_c > 0.01:
		m.roughness_texture = rgh_tex
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	else:
		m.roughness_texture = null

	var ao_s := clampf(float(spec.get("ao_strength", 0.0)), 0.0, 1.0)
	var ao_tex: Texture2D = maps.get("ao")
	m.ao_enabled = ao_tex != null and ao_s > 0.01
	if m.ao_enabled:
		m.ao_texture = ao_tex
		m.ao_light_affect = clampf(ao_s * 0.65, 0.0, 1.0)
	else:
		m.ao_texture = null


static func _resolve_textures(mat_id: String, spec: Dictionary) -> Dictionary:
	var pattern := str(spec.get("pattern", "powder_coat"))
	var grain_s := clampf(float(spec.get("grain_strength", 0.35)), 0.0, 1.0)
	var rough_c := clampf(float(spec.get("rough_contrast", 0.40)), 0.0, 1.0)
	var full_rgb := bool(spec.get("full_color_albedo", false))
	var mode := str(spec.get("texture_mode", "auto"))

	# Baseline procedural maps fill any slot not supplied by CC0 or custom uploads.
	var out := ParametricMaterialSynth.procedural_maps(pattern, grain_s, rough_c).duplicate()

	if mode == "procedural":
		return out

	if mode == "custom":
		var ctex: Dictionary = spec.get("custom_textures", {})
		var have_any_custom := false
		var raw_alb: Texture2D = null
		for slot in MAP_SLOTS:
			if not ctex.has(slot):
				continue
			var rel := str(ctex[slot])
			var t := _load_user_texture(rel)
			if t != null:
				have_any_custom = true
				if slot == "albedo":
					raw_alb = t
					out["albedo"] = t if full_rgb else ParametricMaterialSynth.normalize_albedo_to_grain(t, "usr:" + rel, grain_s)
				else:
					out[slot] = t
		if have_any_custom and raw_alb != null and bool(spec.get("derive_maps", true)):
			var derived := ParametricMaterialSynth.derive_normal_and_roughness(raw_alb, "usr_drv:" + str(ctex.get("albedo", "")), rough_c)
			if not ctex.has("normal") and derived.has("normal"):
				out["normal"] = derived["normal"]
			if not ctex.has("roughness") and derived.has("roughness"):
				out["roughness"] = derived["roughness"]
		if have_any_custom:
			return out

	# `auto` mode (or custom with no uploaded files yet): overlay any discovered CC0 maps.
	var cc0 := resolve_cc0_paths(mat_id)
	for slot in MAP_SLOTS:
		if not cc0.has(slot):
			continue
		var rp := str(cc0[slot])
		var rt := _load_res_texture(rp)
		if rt == null:
			continue
		if slot == "albedo":
			out["albedo"] = rt if full_rgb else ParametricMaterialSynth.normalize_albedo_to_grain(rt, "cc0:" + rp, grain_s)
		else:
			out[slot] = rt
	return out


static func _load_res_texture(res_path: String) -> Texture2D:
	if _res_tex_cache.has(res_path):
		return _res_tex_cache[res_path]
	if not ResourceLoader.exists(res_path):
		return null
	var t := ResourceLoader.load(res_path) as Texture2D
	if t != null:
		_res_tex_cache[res_path] = t
	return t


static func _load_user_texture(rel_or_abs: String) -> Texture2D:
	if rel_or_abs.is_empty():
		return null
	var full := rel_or_abs if (rel_or_abs.begins_with("user://") or rel_or_abs.begins_with("res://")) \
		else _store_root.path_join(rel_or_abs)
	if _user_tex_cache.has(full):
		return _user_tex_cache[full]
	if full.begins_with("res://"):
		return _load_res_texture(full)
	var abs_p := ProjectSettings.globalize_path(full)
	if not FileAccess.file_exists(full) and not FileAccess.file_exists(abs_p):
		return null
	var img := Image.load_from_file(abs_p)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_user_tex_cache[full] = tex
	return tex


static func _register_live(mat_id: String, m: StandardMaterial3D) -> void:
	if not _live_instances.has(mat_id):
		_live_instances[mat_id] = []
	var arr: Array = _live_instances[mat_id]
	arr.append(weakref(m))
	if arr.size() > 512 and (arr.size() % 128) == 0:
		_prune_live(mat_id)


static func _prune_live(mat_id: String) -> void:
	if not _live_instances.has(mat_id):
		return
	var src: Array = _live_instances[mat_id]
	var kept: Array = []
	for wr in src:
		var obj: Object = (wr as WeakRef).get_ref()
		if obj != null and is_instance_valid(obj):
			kept.append(wr)
	_live_instances[mat_id] = kept


## Live-update every existing `StandardMaterial3D` created for `mat_id` in the
## running world and open studios. Returns how many live materials were updated.
static func reapply_live(mat_id: String) -> int:
	_ensure_loaded()
	if not _live_instances.has(mat_id):
		return 0
	var spec := resolved_spec(mat_id)
	var src: Array = _live_instances[mat_id]
	var kept: Array = []
	var count := 0
	for wr in src:
		var m := (wr as WeakRef).get_ref() as StandardMaterial3D
		if m != null and is_instance_valid(m):
			_apply_spec_to_material(m, mat_id, spec)
			kept.append(wr)
			count += 1
	_live_instances[mat_id] = kept
	return count


static func live_instance_count(mat_id: String) -> int:
	_prune_live(mat_id)
	return (_live_instances.get(mat_id, []) as Array).size()


## Set a parameter override on `mat_id`, save to disk (`persist = true`), and
## update all live material instances immediately.
static func set_override(mat_id: String, key: String, value: Variant, persist: bool = true) -> void:
	_ensure_loaded()
	if not _overrides.has(mat_id):
		_overrides[mat_id] = {}
	var ov := _overrides[mat_id] as Dictionary
	if value is Color:
		ov[key] = (value as Color).to_html(true)
	else:
		ov[key] = value
	reapply_live(mat_id)
	if persist:
		save()


## Import a user image file (`png`/`jpg`/`jpeg`/`webp`) into `<store_root>/textures/<mat_id>/<slot>.png`,
## switch `mat_id` to `custom` texture mode, and refresh all live instances.
static func upload_texture(mat_id: String, slot: String, source_path: String) -> Dictionary:
	_ensure_loaded()
	if not MAP_SLOTS.has(slot):
		return {"ok": false, "error": "Unknown texture slot '%s'" % slot}
	if not has_material(mat_id):
		return {"ok": false, "error": "Unknown material '%s'" % mat_id}
	var img: Image = null
	if source_path.begins_with("res://"):
		var rt := _load_res_texture(source_path)
		if rt != null:
			img = rt.get_image()
			if img != null and img.is_compressed():
				img = img.duplicate()
				img.decompress()
	else:
		var abs_src := ProjectSettings.globalize_path(source_path) if source_path.begins_with("user://") else source_path
		img = Image.load_from_file(abs_src)
	if img == null or img.is_empty():
		return {"ok": false, "error": "Could not load image from '%s'" % source_path.get_file()}
	# Cap oversized uploads to 2048×2048 so an 8K phone photo doesn't consume 256 MB VRAM.
	if img.get_width() > 2048 or img.get_height() > 2048:
		var ratio := minf(2048.0 / float(img.get_width()), 2048.0 / float(img.get_height()))
		img = img.duplicate()
		img.resize(maxi(int(round(img.get_width() * ratio)), 4), maxi(int(round(img.get_height() * ratio)), 4), Image.INTERPOLATE_LANCZOS)
	var rel_dir := "%s/%s" % [TEXTURES_SUBDIR, mat_id]
	var abs_dir := ProjectSettings.globalize_path(_store_root.path_join(rel_dir))
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var rel_file := "%s/%s.png" % [rel_dir, slot]
	var full_user := _store_root.path_join(rel_file)
	var err := img.save_png(ProjectSettings.globalize_path(full_user))
	if err != OK:
		return {"ok": false, "error": "Failed saving texture (%d)" % err}

	# Invalidate cached textures for this path so re-uploads update immediately.
	_user_tex_cache.erase(full_user)
	for gk in _prefix_keys(ParametricMaterialSynth._grain_cache, "usr:" + rel_file):
		ParametricMaterialSynth._grain_cache.erase(gk)
	for dk in _prefix_keys(ParametricMaterialSynth._derived_cache, "usr_drv:" + rel_file):
		ParametricMaterialSynth._derived_cache.erase(dk)

	if not _overrides.has(mat_id):
		_overrides[mat_id] = {}
	var ov := _overrides[mat_id] as Dictionary
	var ctex: Dictionary = (ov.get("custom_textures", {}) as Dictionary).duplicate(true)
	ctex[slot] = rel_file
	ov["custom_textures"] = ctex
	ov["texture_mode"] = "custom"
	reapply_live(mat_id)
	save()
	return {"ok": true, "path": full_user, "rel": rel_file, "size": Vector2i(img.get_width(), img.get_height())}


static func clear_uploaded_texture(mat_id: String, slot: String) -> void:
	_ensure_loaded()
	if not _overrides.has(mat_id):
		return
	var ov := _overrides[mat_id] as Dictionary
	if not (ov.get("custom_textures") is Dictionary):
		return
	var ctex := (ov["custom_textures"] as Dictionary).duplicate(true)
	var rel := str(ctex.get(slot, ""))
	ctex.erase(slot)
	ov["custom_textures"] = ctex
	if not rel.is_empty():
		var full := _store_root.path_join(rel)
		_user_tex_cache.erase(full)
		var abs_f := ProjectSettings.globalize_path(full)
		if FileAccess.file_exists(abs_f):
			DirAccess.remove_absolute(abs_f)
	if ctex.is_empty() and str(ov.get("texture_mode", "")) == "custom":
		ov["texture_mode"] = "auto"
	reapply_live(mat_id)
	save()


static func reset_material(mat_id: String) -> void:
	_ensure_loaded()
	if _overrides.has(mat_id):
		var ov := _overrides[mat_id] as Dictionary
		if ov.get("custom_textures") is Dictionary:
			for slot in (ov["custom_textures"] as Dictionary).keys():
				var rel := str(ov["custom_textures"][slot])
				var full := _store_root.path_join(rel)
				_user_tex_cache.erase(full)
				var abs_f := ProjectSettings.globalize_path(full)
				if FileAccess.file_exists(abs_f):
					DirAccess.remove_absolute(abs_f)
		_overrides.erase(mat_id)
	reapply_live(mat_id)
	save()


static func reset_all() -> void:
	_ensure_loaded()
	var ids := _overrides.keys().duplicate()
	for id in ids:
		reset_material(str(id))


## Create a new user-named reusable material cloned from `template_id`.
static func add_custom_material(label: String, template_id: String = "powder_coat") -> String:
	_ensure_loaded()
	var clean_lbl := label.strip_edges()
	if clean_lbl.is_empty():
		clean_lbl = "Custom Material"
	var slug := "user_" + clean_lbl.to_snake_case().replace(" ", "_")
	var candidate := slug
	var n := 2
	while has_material(candidate):
		candidate = "%s_%d" % [slug, n]
		n += 1
	var spec := resolved_spec(template_id)
	spec["id"] = candidate
	spec["label"] = clean_lbl
	spec["category"] = "Your Materials"
	_custom_defs[candidate] = spec
	save()
	return candidate


static func remove_custom_material(mat_id: String) -> bool:
	_ensure_loaded()
	if not is_custom_material(mat_id):
		return false
	reset_material(mat_id)
	_custom_defs.erase(mat_id)
	save()
	return true


static func _prefix_keys(d: Dictionary, prefix: String) -> Array:
	var out := []
	for k in d.keys():
		if str(k).begins_with(prefix):
			out.append(k)
	return out


static func _serialize_spec(spec: Dictionary) -> Dictionary:
	var out := spec.duplicate(true)
	if out.get("default_color") is Color:
		out["default_color"] = (out["default_color"] as Color).to_html(true)
	return out


static func _deserialize_spec(raw: Dictionary) -> Dictionary:
	var out := raw.duplicate(true)
	if out.get("default_color") is String:
		out["default_color"] = Color.from_string(str(out["default_color"]), Color.GRAY)
	return out
